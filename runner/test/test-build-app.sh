#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_ROOT="${REPO_ROOT}/tmp/test-build-app.$$"
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
printf '%s\n' "$@" >"${TEST_LOG_DIR}/xcodebuild-args"

DERIVED_DATA=""
CONFIGURATION="Debug"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -derivedDataPath)
      DERIVED_DATA=$2
      shift 2
      ;;
    -configuration)
      CONFIGURATION=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

APP_DIR="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphonesimulator/App.app"
mkdir -p "$APP_DIR"
cat >"${APP_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.App</string></dict></plist>
PLIST
EOF

cat >"${BIN_DIR}/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_LOG_DIR}/xcrun-calls"
EOF

chmod +x "${BIN_DIR}/xcodebuild" "${BIN_DIR}/xcrun"

run_build() {
  rm -f "${LOG_DIR}/xcodebuild-args" "${LOG_DIR}/xcrun-calls"
  env \
    -u BUILD_EXTRA_ARGS \
    PATH="${BIN_DIR}:$PATH" \
    TEST_LOG_DIR="$LOG_DIR" \
    GITHUB_WORKSPACE="$WORKSPACE" \
    RUNNER_TEMP="$RUNNER_TEMP_DIR" \
    SIMULATOR_UDID="simulator-1" \
    BUILD_PROJECT="App.xcodeproj" \
    BUILD_SCHEME="App" \
    BUILD_CONFIGURATION="Debug" \
    "$@" \
    "${REPO_ROOT}/runner/build-app.sh" >/dev/null
}

assert_xcodebuild_args() {
  local expected=$1
  diff -u "$expected" "${LOG_DIR}/xcodebuild-args"
}

run_build
cat >"${TEST_ROOT}/expected-without-extra-args" <<EOF
-project
${WORKSPACE}/App.xcodeproj
-scheme
App
-destination
platform=iOS Simulator,id=simulator-1
-derivedDataPath
${WORKSPACE}/app-dd
-configuration
Debug
build
EOF
assert_xcodebuild_args "${TEST_ROOT}/expected-without-extra-args"

run_build BUILD_EXTRA_ARGS="-skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO"
cat >"${TEST_ROOT}/expected-with-extra-args" <<EOF
-project
${WORKSPACE}/App.xcodeproj
-scheme
App
-destination
platform=iOS Simulator,id=simulator-1
-derivedDataPath
${WORKSPACE}/app-dd
-configuration
Debug
-skipPackagePluginValidation
COMPILER_INDEX_STORE_ENABLE=NO
build
EOF
assert_xcodebuild_args "${TEST_ROOT}/expected-with-extra-args"

echo "test-build-app: PASS"
