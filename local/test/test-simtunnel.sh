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
# gh run list が返す run（session_runs の --jq 適用後の TSV）と、tailscale status --json の出力
runs_file="${test_dir}/runs.tsv"
peers_file="${test_dir}/peers.json"
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
  cat "$RUNS_FILE"
fi
EOF

cat >"${bin_dir}/git" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "ls-remote" ]; then
  printf '0123456789abcdef0123456789abcdef01234567\trefs/heads/feature\n'
  exit 0
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
printf '200'
EOF

chmod +x "${bin_dir}/gh" "${bin_dir}/git" "${bin_dir}/tailscale" "${bin_dir}/curl"

run_simtunnel() {
  PATH="${bin_dir}:$PATH" \
    GH_LOG="$gh_log" \
    CURL_LOG="$curl_log" \
    SESSION_READY="$session_ready" \
    RUNS_FILE="$runs_file" \
    PEERS_FILE="$peers_file" \
    SIMTUNNEL_REPO="example/repo" \
    "$simtunnel" "$@"
}

# run は 2026-10-21T08:00:00Z に作成された 1 件
printf '111\tin_progress\tfeature\t0123456789abcdef0123456789abcdef01234567\t2026-10-21T08:00:00Z\n' >"$runs_file"

# tailscale status --json の peer を 1 件書く。引数: DNS 名の先頭ラベル / IPv4 / Online / Tags(JSON) / Created
write_peer() {
  cat >>"$peers_file" <<EOF
{"DNSName": "$1.example-tailnet.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::1", "$2"], "Online": $3, "Tags": $4, "Created": "$5"}
EOF
}

# write_peer で書いた peer 群を tailscale status --json の形にまとめる
finish_peers() {
  jq -s '{Peer: (to_entries | map({key: "nodekey:\(.key)", value: .value}) | from_entries)}' "$peers_file" >"${peers_file}.tmp"
  mv "${peers_file}.tmp" "$peers_file"
}

# run の後に参加した tag:ci の runner
write_runner_peer() {
  : >"$peers_file"
  write_peer simtunnel-sample 100.64.0.1 true '["tag:ci"]' 2026-10-21T08:05:00.123456Z
}

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
finish_peers
output=$(run_simtunnel up sample --ref feature --device "iPhone 17 Pro" --duration 30 --wait 2>&1)
grep -q 'workflow run simulator-session.yml -R example/repo --ref feature -f session=sample -f device=iPhone 17 Pro -f duration_minutes=30' "$gh_log"
grep -q 'ready: http://simtunnel-sample:8100 (100.64.0.1)' <<<"$output"

echo "PASS: local/simtunnel の引数解析"

# status が接続した IP を返す（接続しなかった時は空）
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
finish_peers
assert_status_target 100.64.0.1 "tag:ci を持ち run の後に参加したノード"

: >"$peers_file"
write_peer simtunnel-sample 100.64.0.9 true 'null' 2026-10-21T08:05:00Z
finish_peers
assert_status_target "" "tag:ci の無いノード"

: >"$peers_file"
write_peer simtunnel-sample 100.64.0.9 true '["tag:other"]' 2026-10-21T08:05:00Z
finish_peers
assert_status_target "" "tag:ci 以外のタグだけを持つノード"

: >"$peers_file"
write_peer simtunnel-sample 100.64.0.9 true '["tag:ci"]' 2026-10-21T07:59:59.999Z
finish_peers
assert_status_target "" "run より前に作成されたノード（run id で特定した run と一致しない）"

: >"$peers_file"
write_peer simtunnel-sample 100.64.0.9 false '["tag:ci"]' 2026-10-21T08:05:00Z
finish_peers
assert_status_target "" "offline のノード"

: >"$peers_file"
write_peer simtunnel-sample-1 100.64.0.9 true '["tag:ci"]' 2026-10-21T08:05:00Z
finish_peers
assert_status_target "" "MagicDNS 名が一致しないノード"

# 同名を先に名乗った tag:ci の無いノードと正規の runner が並んでも、runner だけを採用する
: >"$peers_file"
write_peer simtunnel-sample 100.64.0.9 true 'null' 2026-10-21T07:00:00Z
write_peer simtunnel-sample 100.64.0.1 true '["tag:ci"]' 2026-10-21T08:05:00Z
finish_peers
assert_status_target 100.64.0.1 "偽ノードと runner の併存"

write_runner_peer
finish_peers
: >"$runs_file"
assert_status_target "" "対象 repo に実行中の run が無い"
printf '111\tin_progress\tfeature\t0123456789abcdef0123456789abcdef01234567\t2026-10-21T08:00:00Z\n' >"$runs_file"

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
write_peer simtunnel-sample 100.64.0.9 true 'null' 2026-10-21T08:05:00Z
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
