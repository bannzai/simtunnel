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

# 起動引数は workflow の「入力を検証」step で文字種・個数・長さを絞ってある。値は public な run ログに出さない。
# 単語分割させるため意図的にクオートしない
# shellcheck disable=SC2086
for u in ${SIMULATOR_UDIDS:-$UDID}; do
  xcrun simctl install "$u" "$APP_PATH"
  echo "installed: ${APP_PATH} (${BUNDLE_ID}) -> ${u}"
  xcrun simctl launch "$u" "$BUNDLE_ID" ${LAUNCH_ARGS:-}
  echo "launched: ${BUNDLE_ID}${LAUNCH_ARGS:+ (with launch args)} -> ${u}"
done
