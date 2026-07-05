#!/bin/bash
# リポジトリ内のサンプルアプリ (iOSProject) をビルドして Simulator に install / launch する。
set -euo pipefail

UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
DD="${ROOT}/app-dd"

xcodebuild \
  -project "${ROOT}/iOSProject/iOSProject.xcodeproj" \
  -scheme iOSProject \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "$DD" \
  -configuration Debug \
  build >"${WORK}/app-build.log" 2>&1 || {
  echo "サンプルアプリのビルドに失敗。ログ末尾:" >&2
  tail -n 150 "${WORK}/app-build.log" >&2
  exit 1
}

APP_PATH=$(find "${DD}/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "ビルド後に .app が見つからない" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Info.plist")

xcrun simctl install "$UDID" "$APP_PATH"
echo "installed: ${APP_PATH} (${BUNDLE_ID})"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "launched: ${BUNDLE_ID}"
