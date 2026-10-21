#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_ROOT="${REPO_ROOT}/tmp/test-install-app.$$"
BIN_DIR="${TEST_ROOT}/bin"
RUNNER_TEMP_DIR="${TEST_ROOT}/runner-temp"
LOG_DIR="${TEST_ROOT}/logs"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$RUNNER_TEMP_DIR" "$LOG_DIR"

cat >"${BIN_DIR}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"${TEST_LOG_DIR}/curl-args"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      touch "$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
EOF

cat >"${BIN_DIR}/ditto" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p "${@: -1}/App.app"
EOF

cat >"${BIN_DIR}/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_LOG_DIR}/xcrun-calls"
EOF

chmod +x "${BIN_DIR}/curl" "${BIN_DIR}/ditto" "${BIN_DIR}/xcrun"

run_install() {
  rm -rf "${RUNNER_TEMP_DIR:?}"/* "${LOG_DIR:?}"/*
  env \
    PATH="${BIN_DIR}:$PATH" \
    TEST_LOG_DIR="$LOG_DIR" \
    RUNNER_TEMP="$RUNNER_TEMP_DIR" \
    SIMULATOR_UDID="simulator-1" \
    APP_ZIP_URL="$1" \
    BUNDLE_ID="com.example.App" \
    "${REPO_ROOT}/runner/install-app.sh" >"${LOG_DIR}/output" 2>&1
}

fail() {
  echo "test-install-app: FAIL: $1" >&2
  cat "${LOG_DIR}/output" >&2
  exit 1
}

# runner は ::add-mask:: の行をログに出さないため、それ以外の行に資格情報が無いことを見る
assert_log_lines_exclude() {
  local secret=$1
  if grep -v '^::add-mask::' "${LOG_DIR}/output" | grep -qF -- "$secret"; then
    fail "ログに ${secret} が含まれる"
  fi
}

assert_output_line() {
  grep -qxF -- "$1" "${LOG_DIR}/output" || fail "出力に「$1」の行が無い"
}

URL='https://user:pass@example.com/bucket/App.zip?X-Amz-Signature=abc%2Fdef&X-Amz-Credential=key#frag'
run_install "$URL"
[ "$(head -1 "${LOG_DIR}/output")" = '::add-mask::https://user:pass@example.com/bucket/App.zip?X-Amz-Signature=abc%252Fdef&X-Amz-Credential=key#frag' ] ||
  fail "最初の行が URL の add-mask ではない"
assert_output_line 'download: https://example.com/bucket/App.zip'
assert_log_lines_exclude 'X-Amz-Signature'
assert_log_lines_exclude 'user:pass'
assert_log_lines_exclude '#frag'
grep -qxF -- "$URL" "${LOG_DIR}/curl-args" || fail "curl に元の URL が渡っていない"

run_install 'https://example.com?token=secret'
assert_output_line 'download: https://example.com'
assert_log_lines_exclude 'token=secret'

run_install $'https://example.com/App.zip?a=1\r\nb=2'
[ "$(head -1 "${LOG_DIR}/output")" = '::add-mask::https://example.com/App.zip?a=1%0D%0Ab=2' ] ||
  fail "改行を含む URL の add-mask が escape されていない"
assert_output_line 'download: https://example.com/App.zip'

# host と path の境界を決められない値は、URL をログに出さず curl も呼ばずに失敗する
for invalid_url in \
  'https:/user:pass@example.com/App.zip?sig=abc' \
  'example.com/App.zip?next=https://evil/?token=secret' \
  'https://user:pass?sig=abc@example.com/App.zip' \
  'https://user:12/pass@example.com/App.zip?sig=abc'; do
  if run_install "$invalid_url"; then
    fail "形式の不正な ${invalid_url} を受け付けた"
  fi
  [ ! -e "${LOG_DIR}/curl-args" ] || fail "形式の不正な ${invalid_url} で curl を呼んだ"
  assert_log_lines_exclude 'user:'
  assert_log_lines_exclude 'sig=abc'
  assert_log_lines_exclude 'token=secret'
done

echo "test-install-app: PASS"
