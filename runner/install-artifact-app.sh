#!/bin/bash
# APP_DIR (actions/download-artifact の展開先) から Simulator 用 .app を特定して install / launch する。
# .app ディレクトリ直置き / .app 入り zip のどちらにも対応する。
set -euo pipefail

UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
APP_DIR="${APP_DIR:?APP_DIR が未設定}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}/artifact-app"
mkdir -p "$WORK"

# zip -r で深い階層ごと固められていても拾えるよう、深さは制限せず nested .app（.app 内の .app）だけ除外する
find_app() {
  find "$1" -name "*.app" -type d -not -path "*.app/*" | head -1
}

APP_PATH=$(find_app "$APP_DIR")
if [ -z "$APP_PATH" ]; then
  ZIP_PATH=$(find "$APP_DIR" -name "*.zip" -type f | head -1)
  if [ -n "$ZIP_PATH" ]; then
    ditto -x -k "$ZIP_PATH" "${WORK}/extracted"
    APP_PATH=$(find_app "${WORK}/extracted")
  fi
fi
[ -n "$APP_PATH" ] || {
  echo "artifact 内に .app / .app 入り zip が見つからない。artifact の中身:" >&2
  find "$APP_DIR" -maxdepth 3 >&2
  echo "upload-artifact の path には .app の親ディレクトリ（例: build/ios/iphonesimulator）を指定する" >&2
  exit 1
}
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Info.plist")

# upload-artifact はパーミッションを保持せず全ファイル 644 になる（README「Permission Loss」）ため、
# .app / .appex / .framework 各バンドルの実行バイナリ (CFBundleExecutable) に実行権限を復元する
find "$APP_PATH" -name Info.plist -print0 | while IFS= read -r -d '' plist; do
  dir=$(dirname "$plist")
  exe=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist" 2>/dev/null) || continue
  if [ -f "${dir}/${exe}" ]; then chmod +x "${dir}/${exe}"; fi
done

for u in ${SIMULATOR_UDIDS:-$UDID}; do
  xcrun simctl install "$u" "$APP_PATH"
  echo "installed: ${APP_PATH} (${BUNDLE_ID}) -> ${u}"
  xcrun simctl launch "$u" "$BUNDLE_ID"
  echo "launched: ${BUNDLE_ID} -> ${u}"
done
