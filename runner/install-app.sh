#!/bin/bash
# APP_ZIP_URL の zip をダウンロードして .app を Simulator に install し、
# BUNDLE_ID があれば launch する。APP_ZIP_URL が空ならスキップ（冪等）。
set -euo pipefail

APP_ZIP_URL="${APP_ZIP_URL:-}"
BUNDLE_ID="${BUNDLE_ID:-}"
UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
UDIDS="${SIMULATOR_UDIDS:-$UDID}"

if [ -z "$APP_ZIP_URL" ]; then
  echo "app_zip_url 未指定のため install をスキップ"
  exit 0
fi

# ログには資格情報が載りうる userinfo・query・fragment を除いた scheme・host・path だけを出す。
# userinfo の / ? # が percent-encode されていない値は host と path の境界を決められず、
# userinfo の一部がログに出るため拒否する。拒否する時も値自体は出さない
url_rest=${APP_ZIP_URL#*://}
url_rest=${url_rest%%[?#]*}
url_authority=${url_rest%%/*}
url_host=${url_authority##*@}
url_path=${url_rest:${#url_authority}}
if [[ ! "$APP_ZIP_URL" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] ||
  [[ ! "$url_host" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?$ ]] ||
  [[ "$url_path" == *@* ]]; then
  echo "app_zip_url は <scheme>://<host>/<path> の形で指定する（userinfo の / ? # @ は percent-encode する）" >&2
  exit 1
fi

# pre-signed URL 等の資格情報を以降の public な run ログに出さない。
# workflow command の data は runner が %25 / %0D / %0A を戻すため、同じ規則で escape して渡す
mask_value=${APP_ZIP_URL//%/%25}
mask_value=${mask_value//$'\r'/%0D}
mask_value=${mask_value//$'\n'/%0A}
echo "::add-mask::${mask_value}"

WORK="${RUNNER_TEMP:-/tmp}/app-install"
mkdir -p "$WORK"

echo "download: ${APP_ZIP_URL%%://*}://${url_host}${url_path}"
curl -fsSL "$APP_ZIP_URL" -o "$WORK/app.zip"
ditto -x -k "$WORK/app.zip" "$WORK/extracted"

APP_PATH=$(find "$WORK/extracted" -maxdepth 3 -name "*.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "zip 内に .app が見つからない" >&2; exit 1; }

for u in $UDIDS; do
  xcrun simctl install "$u" "$APP_PATH"
  echo "installed: ${APP_PATH} -> ${u}"
  if [ -n "$BUNDLE_ID" ]; then
    # 起動引数は workflow の「入力を検証」step で文字種・個数・長さを絞ってある。値は public な run ログに出さない。
    # 単語分割させるため意図的にクオートしない
    # shellcheck disable=SC2086
    xcrun simctl launch "$u" "$BUNDLE_ID" ${LAUNCH_ARGS:-}
    echo "launched: ${BUNDLE_ID}${LAUNCH_ARGS:+ (with launch args)} -> ${u}"
  fi
done
