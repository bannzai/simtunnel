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
  printf '100.64.0.1 simtunnel-sample user linux active\n'
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
    ;;
  *) printf '200' ;;
esac
EOF

chmod +x "${bin_dir}/gh" "${bin_dir}/git" "${bin_dir}/tailscale" "${bin_dir}/curl"

run_simtunnel() {
  PATH="${bin_dir}:$PATH" \
    REAL_GIT="$real_git" \
    GH_LOG="$gh_log" \
    CURL_LOG="$curl_log" \
    SESSION_READY="$session_ready" \
    RUNS_FILE="$runs_file" \
    PEERS_FILE="$peers_file" \
    AGENTD_RUN_IDS_FILE="$agentd_run_ids_file" \
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
