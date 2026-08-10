#!/bin/bash
# WebDriverAgentMac (appium-mac2-driver 同梱) を runner の GUI セッション上で起動し、
# 127.0.0.1:<port> が応答するまで待つ。iOS 版 start-wda.sh の macOS 対応版。
# ビルド成果物 (wda-mac-dd/Build/Products) が復元されていれば test-without-building で即起動し、
# なければ WDA_MAC_REF を clone して build-for-testing でビルドする（成果物は workflow が cache 保存）。
# すでに応答していれば何もしない（冪等）。
# usage: start-wda-mac.sh [port]（省略時は 8100）
set -euo pipefail

PORT="${1:-8100}"
WDA_MAC_REF="${WDA_MAC_REF:-v4.1.1}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PRODUCTS="${ROOT}/wda-mac-dd/Build/Products"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

wda_alive() { curl -s -m 2 "http://127.0.0.1:${PORT}/status" >/dev/null; }

if wda_alive; then
  echo "WDA-mac already running on :${PORT}"
  exit 0
fi

find_xctestrun() {
  # キャッシュ未復元だと $PRODUCTS 自体が存在せず find が非ゼロ終了するため先に確認する
  [ -d "$PRODUCTS" ] || return 0
  find "$PRODUCTS" -maxdepth 1 -name 'WebDriverAgentRunner_*.xctestrun' | head -1
}

XCTESTRUN="$(find_xctestrun)"
if [ -z "$XCTESTRUN" ]; then
  echo "キャッシュなし: WebDriverAgentMac ${WDA_MAC_REF} を build-for-testing でビルドする"
  git clone --depth 1 --branch "$WDA_MAC_REF" https://github.com/appium/appium-mac2-driver.git "${WORK}/appium-mac2-driver"
  xcodebuild \
    -project "${WORK}/appium-mac2-driver/WebDriverAgentMac/WebDriverAgentMac.xcodeproj" \
    -scheme WebDriverAgentRunner \
    -destination "platform=macOS" \
    -derivedDataPath "${ROOT}/wda-mac-dd" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build-for-testing >"${WORK}/wda-mac-build.log" 2>&1 || {
    echo "WebDriverAgentMac のビルドに失敗。ログ末尾:" >&2
    tail -n 150 "${WORK}/wda-mac-build.log" >&2
    exit 1
  }
  XCTESTRUN="$(find_xctestrun)"
  [ -n "$XCTESTRUN" ] || { echo "ビルド後も xctestrun が見つからない: ${PRODUCTS}" >&2; exit 1; }
else
  echo "キャッシュあり: ビルドをスキップして起動する"
fi

# xctestrun のテストターゲットキー（__xctestrun_metadata__ 以外の先頭キー）
TARGET_KEY=$(plutil -convert json -o - "$XCTESTRUN" | jq -r 'keys[] | select(. != "__xctestrun_metadata__")' | head -1)
[ -n "$TARGET_KEY" ] || { echo "xctestrun のテストターゲットキーが特定できない: ${XCTESTRUN}" >&2; exit 1; }

# plist の指定キーを上書き（無ければ追加）する
plist_set() {
  local file=$1 keypath=$2 value=$3
  /usr/libexec/PlistBuddy -c "Set :${keypath} ${value}" "$file" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${keypath} string ${value}" "$file"
}

LOG="${WORK}/wda-mac-${PORT}.log"

# ポートは xctestrun のコピーに環境変数として注入する（xcodebuild のプロセス env も併せて渡す）。
# xctestrun 内の成果物パスは __TESTROOT__（= xctestrun のあるディレクトリ）相対のため、
# コピーは元と同じディレクトリに置く（find_xctestrun のパターンに掛からない名前にする）
RUN_FILE="${PRODUCTS}/wda-mac-port-${PORT}.xctestrun"
cp "$XCTESTRUN" "$RUN_FILE"
plist_set "$RUN_FILE" "${TARGET_KEY}:TestingEnvironmentVariables:USE_PORT" "$PORT"
plist_set "$RUN_FILE" "${TARGET_KEY}:EnvironmentVariables:USE_PORT" "$PORT"

# test-without-building は WDA が動いている間ずっと走り続けるため、バックグラウンドで起動する
USE_PORT="$PORT" nohup xcodebuild \
  test-without-building \
  -xctestrun "$RUN_FILE" \
  -destination "platform=macOS" >"$LOG" 2>&1 &
echo "WDA-mac launching -> :${PORT}"

echo "WDA-mac の起動を待機中（最大 5 分）..."
for _ in $(seq 1 60); do
  if wda_alive; then
    echo "WDA-mac ready: http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 5
done
echo "WDA-mac :${PORT} が 5 分以内に起動しなかった。ログ末尾:" >&2
tail -n 200 "$LOG" >&2
exit 1
