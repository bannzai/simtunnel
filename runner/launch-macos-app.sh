#!/bin/bash
# ビルド済み .app を LaunchServices に登録し、起動する。
# 登録することで WDA-mac のセッション作成 (appium:bundleId) から起動できるようになる。
# usage: launch-macos-app.sh（MAC_APP_PATH / MAC_BUNDLE_ID を env で受け取る）
set -euo pipefail

APP="${MAC_APP_PATH:?MAC_APP_PATH が未設定}"
BUNDLE_ID="${MAC_BUNDLE_ID:?MAC_BUNDLE_ID が未設定}"
[ -d "$APP" ] || { echo ".app が存在しない: ${APP}" >&2; exit 1; }

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP"
  echo "registered with LaunchServices: ${APP}"
fi

# GUI セッションで起動する（screenshot の初期確認用。WDA セッション作成でも起動されるが冪等）
open "$APP"
echo "launched: ${BUNDLE_ID}"
