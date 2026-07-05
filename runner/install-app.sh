#!/bin/bash
# APP_ZIP_URL の zip をダウンロードして .app を Simulator に install し、
# BUNDLE_ID があれば launch する。APP_ZIP_URL が空ならスキップ（冪等）。
set -euo pipefail

APP_ZIP_URL="${APP_ZIP_URL:-}"
BUNDLE_ID="${BUNDLE_ID:-}"
UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"

if [ -z "$APP_ZIP_URL" ]; then
  echo "app_zip_url 未指定のため install をスキップ"
  exit 0
fi

WORK="${RUNNER_TEMP:-/tmp}/app-install"
mkdir -p "$WORK"

echo "download: ${APP_ZIP_URL}"
curl -fsSL "$APP_ZIP_URL" -o "$WORK/app.zip"
ditto -x -k "$WORK/app.zip" "$WORK/extracted"

APP_PATH=$(find "$WORK/extracted" -maxdepth 3 -name "*.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "zip 内に .app が見つからない" >&2; exit 1; }

xcrun simctl install "$UDID" "$APP_PATH"
echo "installed: ${APP_PATH}"

if [ -n "$BUNDLE_ID" ]; then
  xcrun simctl launch "$UDID" "$BUNDLE_ID"
  echo "launched: ${BUNDLE_ID}"
fi
