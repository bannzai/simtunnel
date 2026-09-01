#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
simtunnel="${repo_root}/local/simtunnel"
mkdir -p "${repo_root}/tmp"
test_dir=$(mktemp -d "${repo_root}/tmp/test-simtunnel.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

bin_dir="${test_dir}/bin"
gh_log="${test_dir}/gh.log"
session_ready="${test_dir}/session-ready"
mkdir -p "$bin_dir"
: >"$gh_log"

cat >"${bin_dir}/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = "workflow" ] && [ "${2:-}" = "run" ]; then
  : >"$SESSION_READY"
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
if [ -f "$SESSION_READY" ]; then
  printf '100.64.0.1 simtunnel-sample user linux active\n'
fi
EOF

cat >"${bin_dir}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '200'
EOF

chmod +x "${bin_dir}/gh" "${bin_dir}/git" "${bin_dir}/tailscale" "${bin_dir}/curl"

run_simtunnel() {
  PATH="${bin_dir}:$PATH" \
    GH_LOG="$gh_log" \
    SESSION_READY="$session_ready" \
    SIMTUNNEL_REPO="example/repo" \
    "$simtunnel" "$@"
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

: >"$gh_log"
if output=$(run_simtunnel up -mistaken-flag 2>&1); then
  echo "- で始まる session 名が受理された" >&2
  exit 1
fi
grep -q 'session 名は - で開始できない: -mistaken-flag' <<<"$output"
if [ -s "$gh_log" ]; then
  echo "不正な session 名で GitHub CLI が呼ばれた" >&2
  cat "$gh_log" >&2
  exit 1
fi

rm -f "$session_ready"
: >"$gh_log"
output=$(run_simtunnel up sample --ref feature --device "iPhone 17 Pro" --duration 30 --wait 2>&1)
grep -q 'workflow run simulator-session.yml -R example/repo --ref feature -f session=sample -f device=iPhone 17 Pro -f duration_minutes=30' "$gh_log"
grep -q 'ready: http://simtunnel-sample:8100' <<<"$output"

echo "PASS: local/simtunnel の引数解析"
