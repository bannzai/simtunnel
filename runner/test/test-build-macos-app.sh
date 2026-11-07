#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_ROOT="${REPO_ROOT}/tmp/test-build-macos-app.$$"
BIN_DIR="${TEST_ROOT}/bin"
WORKSPACE="${TEST_ROOT}/workspace"
RUNNER_TEMP_DIR="${TEST_ROOT}/runner-temp"
LOG_DIR="${TEST_ROOT}/logs"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$WORKSPACE" "$RUNNER_TEMP_DIR" "$LOG_DIR"
touch "$WORKSPACE/App.xcodeproj"

cat >"${BIN_DIR}/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail

DERIVED_DATA=""
ACTION=""
for arg in "$@"; do
  case "$arg" in
    build) ACTION=build ;;
    -showBuildSettings) ACTION=settings ;;
  esac
done
PREVIOUS=""
for arg in "$@"; do
  [ "$PREVIOUS" = "-derivedDataPath" ] && DERIVED_DATA=$arg
  PREVIOUS=$arg
done

printf '%s\n' "$@" >"${TEST_LOG_DIR}/xcodebuild-args-${ACTION}"

APP_DIR="${DERIVED_DATA}/Build/Products/Debug/App.app"
if [ "$ACTION" = "settings" ]; then
  echo "    TARGET_BUILD_DIR = ${DERIVED_DATA}/Build/Products/Debug"
  echo "    WRAPPER_NAME = App.app"
  exit 0
fi

mkdir -p "${APP_DIR}/Contents"
cat >"${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.App</string></dict></plist>
PLIST
EOF

chmod +x "${BIN_DIR}/xcodebuild"

# 引数の VAR=value を環境変数に足して build-macos-app.sh を実行する。前回の xcodebuild の記録と GITHUB_ENV は消す
run_build() {
  rm -f "${LOG_DIR}/xcodebuild-args-build" "${LOG_DIR}/xcodebuild-args-settings" "${LOG_DIR}/github-env"
  (
    # "*" の展開先になるファイルがあるディレクトリで実行する
    cd "$WORKSPACE"
    env \
      -u BUILD_EXTRA_ARGS \
      -u SAMPLE_APP \
      PATH="${BIN_DIR}:$PATH" \
      TEST_LOG_DIR="$LOG_DIR" \
      GITHUB_WORKSPACE="$WORKSPACE" \
      GITHUB_ENV="${LOG_DIR}/github-env" \
      RUNNER_TEMP="$RUNNER_TEMP_DIR" \
      BUILD_PROJECT="App.xcodeproj" \
      BUILD_SCHEME="App" \
      BUILD_CONFIGURATION="Debug" \
      "$@" \
      "${REPO_ROOT}/runner/build-macos-app.sh" >/dev/null
  )
}

# ビルドと -showBuildSettings の両方の xcodebuild の引数を、期待する追加の引数と照合する
assert_xcodebuild_args() {
  local extra_args_file=$1
  {
    cat "${TEST_ROOT}/expected-common-args"
    cat "$extra_args_file"
    echo build
  } >"${TEST_ROOT}/expected-build"
  {
    cat "${TEST_ROOT}/expected-common-args"
    cat "$extra_args_file"
    echo -showBuildSettings
  } >"${TEST_ROOT}/expected-settings"
  diff -u "${TEST_ROOT}/expected-build" "${LOG_DIR}/xcodebuild-args-build"
  diff -u "${TEST_ROOT}/expected-settings" "${LOG_DIR}/xcodebuild-args-settings"
}

cat >"${TEST_ROOT}/expected-common-args" <<EOF
-project
${WORKSPACE}/App.xcodeproj
-scheme
App
-destination
platform=macOS
-derivedDataPath
${WORKSPACE}/macos-app-dd
-configuration
Debug
EOF

: >"${TEST_ROOT}/no-extra-args"

run_build
assert_xcodebuild_args "${TEST_ROOT}/no-extra-args"
grep -qx "MAC_BUNDLE_ID=com.example.App" "${LOG_DIR}/github-env"

run_build BUILD_EXTRA_ARGS=$' \t\n '
assert_xcodebuild_args "${TEST_ROOT}/no-extra-args"

run_build BUILD_EXTRA_ARGS="-skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO"
printf '%s\n' -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO >"${TEST_ROOT}/two-extra-args"
assert_xcodebuild_args "${TEST_ROOT}/two-extra-args"

run_build BUILD_EXTRA_ARGS="*"
printf '%s\n' '*' >"${TEST_ROOT}/glob-extra-arg"
assert_xcodebuild_args "${TEST_ROOT}/glob-extra-arg"

echo "test-build-macos-app: PASS"
