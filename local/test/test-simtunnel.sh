#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
simtunnel="${repo_root}/local/simtunnel"
mkdir -p "${repo_root}/tmp"
test_dir=$(mktemp -d "${repo_root}/tmp/test-simtunnel.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

bin_dir="${test_dir}/bin"
gh_log="${test_dir}/gh.log"
curl_log="${test_dir}/curl.log"
session_ready="${test_dir}/session-ready"
curl_post_log="${test_dir}/curl-post.log"
open_log="${test_dir}/open.log"
# gh run list が返す run（runID / status / headBranch / headSha の TSV。--status in_progress の時は runID だけを返す）
runs_file="${test_dir}/runs.tsv"
# tailscale status --json の出力
peers_file="${test_dir}/peers.json"
# 各ノードの agentd が /status で返す run_id（"<IPv4> <run_id>" の行。行の無い IP の agentd は応答しない）
agentd_run_ids_file="${test_dir}/agentd-run-ids"
real_git=$(command -v git)
mkdir -p "$bin_dir"
: >"$gh_log"

cat >"${bin_dir}/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = "workflow" ] && [ "${2:-}" = "run" ]; then
  : >"$SESSION_READY"
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ] && [ -f "$SESSION_READY" ]; then
  case " $* " in
    *" --status in_progress "*) cut -f1 "$RUNS_FILE" ;;
    *) cat "$RUNS_FILE" ;;
  esac
fi
EOF

cat >"${bin_dir}/git" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "ls-remote" ]; then
  printf '0123456789abcdef0123456789abcdef01234567\trefs/heads/feature\n'
  exit 0
fi
# mcp-config が .mcp.json の ignore 状態を調べる呼び出しは実物の git で答える
if [ "${1:-}" = "-C" ]; then
  exec "$REAL_GIT" "$@"
fi
exit 1
EOF

cat >"${bin_dir}/tailscale" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ ! -f "$SESSION_READY" ]; then
  [ "${2:-}" = "--json" ] && printf '{"Peer":{}}\n'
  exit 0
fi
if [ "${2:-}" = "--json" ]; then
  cat "$PEERS_FILE"
else
  # 実物の tailscale status と同じく、offline のノードの 5 列目は "offline," になる
  jq -r '.Peer[]? | [([.TailscaleIPs[] | select(test("^[0-9.]+$"))][0]), (.DNSName | split(".")[0]), "tagged-devices", "macOS", (if .Online then "active" else "offline, last seen 29m ago" end)] | join("  ")' "$PEERS_FILE"
fi
EOF

cat >"${bin_dir}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$CURL_LOG"
url="${!#}"
case "$url" in
  http://*:8200/status)
    ip=${url#http://}
    ip=${ip%%:*}
    run_id=$(awk -v ip="$ip" '$1 == ip {print $2; exit}' "$AGENTD_RUN_IDS_FILE")
    [ -n "$run_id" ] || exit 7
    printf '{"ok": true, "run_id": "%s"}\n' "$run_id"
    exit 0
    ;;
esac
case "$*" in
  *:8200/token*) printf '{"token": "test-token"}' ;;
  *:8200/v1/*)
    # -H @- で渡されたトークンのヘッダーも記録する
    { printf '%s\n' "$*"; cat; } >"$CURL_POST_LOG"
    printf '{"ok": true}'
    ;;
  *) printf '200' ;;
esac
EOF

# preview がブラウザで開く URL を記録する
cat >"${bin_dir}/open" <<'EOF'
#!/bin/bash
printf '%s' "$1" >"$OPEN_LOG"
EOF

chmod +x "${bin_dir}/gh" "${bin_dir}/git" "${bin_dir}/tailscale" "${bin_dir}/curl" "${bin_dir}/open"

run_simtunnel() {
  PATH="${bin_dir}:$PATH" \
    REAL_GIT="$real_git" \
    GH_LOG="$gh_log" \
    CURL_LOG="$curl_log" \
    SESSION_READY="$session_ready" \
    RUNS_FILE="$runs_file" \
    PEERS_FILE="$peers_file" \
    AGENTD_RUN_IDS_FILE="$agentd_run_ids_file" \
    CURL_POST_LOG="$curl_post_log" \
    OPEN_LOG="$open_log" \
    SIMTUNNEL_REPO="example/repo" \
    "$simtunnel" "$@"
}

# 対象 repo の in_progress の run は 111 の 1 件
write_runs() {
  printf '111\tin_progress\tfeature\t0123456789abcdef0123456789abcdef01234567\n' >"$runs_file"
}

# tailscale status --json の peer を 1 件書く。引数: HostName / MagicDNS 名の先頭ラベル / IPv4 / Online / Tags(JSON)
write_peer() {
  cat >>"$peers_file" <<EOF
{"HostName": "$1", "DNSName": "$2.example-tailnet.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::1", "$3"], "Online": $4, "Tags": $5}
EOF
}

# write_peer で書いた peer 群を tailscale status --json の形にまとめる
finish_peers() {
  jq -s '{Peer: (to_entries | map({key: "nodekey:\(.key)", value: .value}) | from_entries)}' "$peers_file" >"${peers_file}.tmp"
  mv "${peers_file}.tmp" "$peers_file"
}

# run 111 が起動した tag:ci の runner だけがいる状態
write_runner_peer() {
  : >"$peers_file"
  write_peer simtunnel-sample simtunnel-sample 100.64.0.1 true '["tag:ci"]'
  finish_peers
  printf '100.64.0.1 111\n' >"$agentd_run_ids_file"
}

write_runs
: >"$agentd_run_ids_file"

assert_help_without_dispatch() {
  local expected_status=$1
  shift
  local output status
  : >"$gh_log"
  if output=$(run_simtunnel "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne "$expected_status" ]; then
    echo "終了コードが想定外: expected=${expected_status} actual=${status} args=$*" >&2
    return 1
  fi
  grep -q '^使い方:$' <<<"$output" || {
    echo "使い方が表示されなかった: args=$*" >&2
    return 1
  }
  if [ -s "$gh_log" ]; then
    echo "GitHub CLI が呼ばれた: args=$*" >&2
    cat "$gh_log" >&2
    return 1
  fi
}

assert_help_without_dispatch 0
assert_help_without_dispatch 0 --help
assert_help_without_dispatch 0 -h
assert_help_without_dispatch 0 --help up
assert_help_without_dispatch 0 up --help
assert_help_without_dispatch 0 up -h
assert_help_without_dispatch 1 up

assert_invalid_session_without_dispatch() {
  local session=$1
  local output
  : >"$gh_log"
  if output=$(run_simtunnel up "$session" 2>&1); then
    echo "不正な session 名が受理された: ${session}" >&2
    return 1
  fi
  grep -q 'session 名は小文字英数字で始まり、小文字英数字とハイフンのみ使用できる' <<<"$output"
  if [ -s "$gh_log" ]; then
    echo "不正な session 名で GitHub CLI が呼ばれた: ${session}" >&2
    cat "$gh_log" >&2
    return 1
  fi
}

assert_invalid_session_without_dispatch -mistaken-flag
assert_invalid_session_without_dispatch ""
assert_invalid_session_without_dispatch bad/name

rm -f "$session_ready"
: >"$gh_log"
write_runner_peer
output=$(run_simtunnel up sample --ref feature --device "iPhone 17 Pro" --duration 30 --wait 2>&1)
grep -q 'workflow run simulator-session.yml -R example/repo --ref feature -f session=sample -f device=iPhone 17 Pro -f duration_minutes=30' "$gh_log"
grep -q 'ready: http://100.64.0.1:8100' <<<"$output"

# agentd の POST に Content-Type と GET /token で取得したトークンが付く
run_simtunnel agentd sample relaunch '{"args": ["-UITEST"]}' >/dev/null
grep -q -- '-X POST http://100.64.0.1:8200/v1/relaunch -H Content-Type: application/json -H @- -d {"args": \["-UITEST"\]}' "$curl_post_log"
grep -qx 'X-Simtunnel-Token: test-token' "$curl_post_log"
if run_simtunnel agentd sample '../status' >/dev/null 2>&1; then
  echo "不正な動詞が受理された" >&2
  exit 1
fi

echo "PASS: local/simtunnel の引数解析"

# status が WDA の /status に接続した IP を返す（接続しなかった時は空）
status_target_ip() {
  : >"$curl_log"
  run_simtunnel status sample >/dev/null 2>&1 || true
  sed -n 's|.*http://\([0-9.]*\):8100/status.*|\1|p' "$curl_log"
}

assert_status_target() {
  local expected=$1 description=$2 actual
  actual=$(status_target_ip)
  if [ "$actual" != "$expected" ]; then
    echo "${description}: 接続先が想定外 expected='${expected}' actual='${actual}'" >&2
    return 1
  fi
}

: >"$session_ready"

write_runner_peer
assert_status_target 100.64.0.1 "tag:ci を持ち、agentd が対象の run id を返すノード"

: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true 'null'
finish_peers
printf '100.64.0.9 111\n' >"$agentd_run_ids_file"
assert_status_target "" "tag:ci の無いノード（agentd が対象の run id を返しても採用しない）"

: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true '["tag:other"]'
finish_peers
assert_status_target "" "tag:ci 以外のタグだけを持つノード"

: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 false '["tag:ci"]'
finish_peers
assert_status_target "" "offline のノード"

: >"$peers_file"
write_peer simtunnel-other simtunnel-other 100.64.0.9 true '["tag:ci"]'
finish_peers
assert_status_target "" "HostName が一致しないノード"

: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true '["tag:ci"]'
finish_peers
printf '100.64.0.9 222\n' >"$agentd_run_ids_file"
assert_status_target "" "agentd が別の run id を返すノード（別 repo の同名セッション）"

: >"$agentd_run_ids_file"
assert_status_target "" "agentd が応答しないノード"

# 別 repo の同名セッションが先に参加し、対象の runner の MagicDNS 名に接尾辞が付いても、対象の runner を採用する
: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true '["tag:ci"]'
write_peer simtunnel-sample simtunnel-sample-1 100.64.0.1 true '["tag:ci"]'
finish_peers
printf '100.64.0.9 222\n100.64.0.1 111\n' >"$agentd_run_ids_file"
assert_status_target 100.64.0.1 "別 repo の同名セッションと runner の併存"

# 同名を名乗った tag:ci の無いノードと正規の runner が並んでも、runner だけを採用する
: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true 'null'
write_peer simtunnel-sample simtunnel-sample-1 100.64.0.1 true '["tag:ci"]'
finish_peers
printf '100.64.0.9 111\n100.64.0.1 111\n' >"$agentd_run_ids_file"
assert_status_target 100.64.0.1 "tag:ci の無い偽ノードと runner の併存"

write_runner_peer
: >"$runs_file"
assert_status_target "" "対象 repo に実行中の run が無い"
write_runs

echo "PASS: session_ip の接続先検証"

# preview は検証したノード自身の MagicDNS 名で開く（先着の別ノードに解決される simtunnel-sample ではなく -1 の方）
: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true '["tag:ci"]'
write_peer simtunnel-sample simtunnel-sample-1 100.64.0.1 true '["tag:ci"]'
finish_peers
printf '100.64.0.9 222\n100.64.0.1 111\n' >"$agentd_run_ids_file"
run_simtunnel preview sample >/dev/null
[ "$(cat "$open_log")" = "http://simtunnel-sample-1.example-tailnet.ts.net:3200" ] || {
  echo "preview が検証済みノードの MagicDNS 名を開いていない: $(cat "$open_log")" >&2
  exit 1
}

echo "PASS: preview の接続先"

mcp_dir="${test_dir}/mcp"
mkdir -p "$mcp_dir"
run_simtunnel mcp-config sample "$mcp_dir" --slot 1 >/dev/null
[ "$(jq -r '.mcpServers.simtunnel.env.SIMTUNNEL_WDA_URL' "${mcp_dir}/.mcp.json")" = "http://100.64.0.1:8101" ] || {
  echo ".mcp.json の URL が検証済みノードの IP を指していない" >&2
  cat "${mcp_dir}/.mcp.json" >&2
  exit 1
}

: >"$peers_file"
write_peer simtunnel-sample simtunnel-sample 100.64.0.9 true 'null'
finish_peers
if run_simtunnel mcp-config sample "$mcp_dir" >/dev/null 2>&1; then
  echo "検証できないノードしか無いのに mcp-config が成功した" >&2
  exit 1
fi
[ "$(jq -r '.mcpServers.simtunnel.env.SIMTUNNEL_WDA_URL' "${mcp_dir}/.mcp.json")" = "http://100.64.0.1:8101" ] || {
  echo "検証に失敗した mcp-config が .mcp.json を書き換えた" >&2
  exit 1
}

echo "PASS: mcp-config の接続先"

write_runner_peer
unignored_repo="${test_dir}/unignored-repo"
mkdir -p "$unignored_repo"
# test_dir は simtunnel リポジトリの ignore 済みの tmp/ 配下のため、独立した git リポジトリを作る
"$real_git" init -q "$unignored_repo"
if run_simtunnel mcp-config sample "$unignored_repo" >/dev/null 2>&1; then
  echo ".mcp.json が ignore されていないリポジトリで mcp-config が成功した" >&2
  exit 1
fi
[ ! -e "${unignored_repo}/.mcp.json" ] || { echo "ignore されていない .mcp.json に実 IP を書いた" >&2; exit 1; }

printf '.mcp.json\n' >>"${unignored_repo}/.git/info/exclude"
run_simtunnel mcp-config sample "$unignored_repo" >/dev/null
[ -f "${unignored_repo}/.mcp.json" ] || { echo "ignore 済みの .mcp.json を書かなかった" >&2; exit 1; }

echo "PASS: mcp-config は ignore されていない .mcp.json に書かない"

# 待機の sleep の間に旧ノードの登録が tailnet から消えた状態を作る
cat >"${bin_dir}/sleep" <<'EOF'
#!/bin/bash
printf '{"Peer":{}}\n' >"$PEERS_FILE"
EOF
chmod +x "${bin_dir}/sleep"

# 期限切れのセッションの offline のノードだけが残り、対象 repo に run が無い状態
write_offline_peer() {
  : >"$peers_file"
  write_peer simtunnel-sample simtunnel-sample 100.64.0.1 false '["tag:ci"]'
  finish_peers
}

: >"$runs_file"
write_offline_peer
: >"$gh_log"
output=$(run_simtunnel up sample 2>&1) || {
  echo "offline のノードだけが残る同名セッションの up が失敗した" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
if grep -q 'tailnet に存在するが' <<<"$output"; then
  echo "offline のノードを online と判定し、repo の取り違えを案内した" >&2
  exit 1
fi
grep -q '登録が tailnet から消えるのを待機中' <<<"$output"
grep -q '^workflow run simulator-session.yml -R example/repo -f session=sample ' "$gh_log"

write_offline_peer
if run_simtunnel down sample >/dev/null 2>&1; then :; else
  echo "offline のノードだけが残る down が冪等に成功しなかった" >&2
  exit 1
fi

write_runner_peer
: >"$gh_log"
if output=$(run_simtunnel up sample 2>&1); then
  echo "online のノードがあり run が無いのに up が成功した" >&2
  exit 1
fi
grep -q 'tailnet に存在するが、example/repo に対象 run が見つからない' <<<"$output"
if grep -q '^workflow run' "$gh_log"; then
  echo "repo の取り違えの疑いがあるのに dispatch した" >&2
  exit 1
fi
write_runs

echo "PASS: session_node_online は offline のノードを online としない"

# 待機の sleep の回数を数える（1 回 15 秒）
sleep_log="${test_dir}/sleep.log"
cat >"${bin_dir}/sleep" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >>"${sleep_log}"
EOF
chmod +x "${bin_dir}/sleep"

# 準備完了しないセッションは SIMTUNNEL_WAIT_MINUTES 分（15 秒 × 分 × 4 回）で待機を打ち切る
printf '{"Peer":{}}\n' >"$peers_file"
: >"$sleep_log"
if output=$(SIMTUNNEL_WAIT_MINUTES=2 run_simtunnel wait sample 2>&1); then
  echo "準備完了しないセッションの wait が成功した" >&2
  exit 1
fi
[ "$(wc -l <"$sleep_log" | tr -d ' ')" = "8" ] || {
  echo "SIMTUNNEL_WAIT_MINUTES=2 の待機回数が 8 回でない: $(wc -l <"$sleep_log" | tr -d ' ')" >&2
  exit 1
}
grep -q '2 分以内に準備完了しなかった' <<<"$output"

# 既定の上限は 20 分（80 回）。テストを実行する環境の値を継がないよう外す
: >"$sleep_log"
(unset SIMTUNNEL_WAIT_MINUTES; run_simtunnel wait sample >/dev/null 2>&1) || true
[ "$(wc -l <"$sleep_log" | tr -d ' ')" = "80" ] || {
  echo "既定の待機回数が 80 回でない: $(wc -l <"$sleep_log" | tr -d ' ')" >&2
  exit 1
}

# 不正な値は dispatch の前に止める
assert_invalid_wait_minutes_without_dispatch() {
  local value=$1
  local output
  : >"$gh_log"
  : >"$runs_file"
  if output=$(SIMTUNNEL_WAIT_MINUTES="$value" run_simtunnel up sample --wait 2>&1); then
    echo "不正な SIMTUNNEL_WAIT_MINUTES が受理された: ${value}" >&2
    return 1
  fi
  grep -q 'SIMTUNNEL_WAIT_MINUTES は 1〜360 の整数' <<<"$output"
  if grep -q '^workflow run' "$gh_log"; then
    echo "不正な SIMTUNNEL_WAIT_MINUTES で dispatch した: ${value}" >&2
    return 1
  fi
}

assert_invalid_wait_minutes_without_dispatch 0
assert_invalid_wait_minutes_without_dispatch 010
assert_invalid_wait_minutes_without_dispatch abc
assert_invalid_wait_minutes_without_dispatch -5
# 4 倍すると bash の 64bit 整数が負に折り返し、1 回も待たずに失敗する値
assert_invalid_wait_minutes_without_dispatch 2305843009213693952
assert_invalid_wait_minutes_without_dispatch 361
write_runs

echo "PASS: SIMTUNNEL_WAIT_MINUTES で待機の上限を変えられる"
