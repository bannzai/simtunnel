#!/bin/bash
# APP_DIR (actions/download-artifact の展開先) から Simulator 用 .app を特定して install / launch する。
# .app ディレクトリ直置き / .app 入り zip のどちらにも対応する。
set -euo pipefail

UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
APP_DIR="${APP_DIR:?APP_DIR が未設定}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}/artifact-app"
mkdir -p "$WORK"

APP_PATH=$(find "$APP_DIR" -maxdepth 3 -name "*.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  ZIP_PATH=$(find "$APP_DIR" -maxdepth 2 -name "*.zip" -type f | head -1)
  if [ -n "$ZIP_PATH" ]; then
    ditto -x -k "$ZIP_PATH" "${WORK}/extracted"
    APP_PATH=$(find "${WORK}/extracted" -maxdepth 3 -name "*.app" -type d | head -1)
  fi
fi
[ -n "$APP_PATH" ] || {
  echo "artifact 内に .app / .app 入り zip が見つからない。artifact の中身:" >&2
  find "$APP_DIR" -maxdepth 3 >&2
  echo "upload-artifact の path には .app の親ディレクトリ（例: build/ios/iphonesimulator）を指定する" >&2
  exit 1
}
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Info.plist")

xcrun simctl install "$UDID" "$APP_PATH"
echo "installed: ${APP_PATH} (${BUNDLE_ID})"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "launched: ${BUNDLE_ID}"
