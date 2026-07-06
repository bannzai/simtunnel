#!/bin/bash
# BUILD_PROJECT (.xcodeproj / .xcworkspace) を BUILD_SCHEME でビルドして Simulator に install / launch する。
# bundle id はビルド成果物の Info.plist から取得するため指定不要。
set -euo pipefail

UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
PROJECT="${BUILD_PROJECT:?BUILD_PROJECT が未設定}"
SCHEME="${BUILD_SCHEME:?BUILD_SCHEME が未設定}"
CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
DD="${ROOT}/app-dd"
mkdir -p "$WORK"

case "$PROJECT" in
  *.xcworkspace) CONTAINER=(-workspace "${ROOT}/${PROJECT}") ;;
  *) CONTAINER=(-project "${ROOT}/${PROJECT}") ;;
esac

xcodebuild \
  "${CONTAINER[@]}" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "$DD" \
  -configuration "$CONFIGURATION" \
  build >"${WORK}/app-build.log" 2>&1 || {
  echo "アプリのビルドに失敗。ログ末尾:" >&2
  tail -n 150 "${WORK}/app-build.log" >&2
  exit 1
}

APP_PATH=$(find "${DD}/Build/Products/${CONFIGURATION}-iphonesimulator" -maxdepth 1 -name "*.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "ビルド後に .app が見つからない" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Info.plist")

xcrun simctl install "$UDID" "$APP_PATH"
echo "installed: ${APP_PATH} (${BUNDLE_ID})"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "launched: ${BUNDLE_ID}"
