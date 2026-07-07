#!/bin/bash
# WebDriverAgent を各 Simulator 上で起動し、127.0.0.1:<port> が応答するまで待つ。
# i 台目 (0 始まり) の WDA は :8100+i / MJPEG は :9100+i。
# ビルド成果物 (wda-dd/Build/Products) が復元されていれば test-without-building で即起動し、
# なければ WDA_REF を clone して build-for-testing でビルドする（成果物は workflow が cache 保存）。
# すでに応答しているポートの Simulator はスキップする（冪等）。
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: start-wda.sh <simulator-udid> [udid...]" >&2; exit 1; }
UDIDS=("$@")
WDA_REF="${WDA_REF:-master}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PRODUCTS="${ROOT}/wda-dd/Build/Products"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

wda_alive() { curl -s -m 2 "http://127.0.0.1:$1/status" >/dev/null; }

find_xctestrun() {
  # キャッシュ未復元だと $PRODUCTS 自体が存在せず find が非ゼロ終了するため先に確認する
  [ -d "$PRODUCTS" ] || return 0
  find "$PRODUCTS" -maxdepth 1 -name 'WebDriverAgentRunner_*.xctestrun' | head -1
}

XCTESTRUN="$(find_xctestrun)"
if [ -z "$XCTESTRUN" ]; then
  echo "キャッシュなし: WDA ${WDA_REF} を build-for-testing でビルドする"
  git clone --depth 1 --branch "$WDA_REF" https://github.com/appium/WebDriverAgent.git "${WORK}/WebDriverAgent"
  xcodebuild \
    -project "${WORK}/WebDriverAgent/WebDriverAgent.xcodeproj" \
    -scheme WebDriverAgentRunner \
    -destination "platform=iOS Simulator,id=${UDIDS[0]}" \
    -derivedDataPath "${ROOT}/wda-dd" \
    build-for-testing >"${WORK}/wda-build.log" 2>&1 || {
    echo "WDA のビルドに失敗。ログ末尾:" >&2
    tail -n 150 "${WORK}/wda-build.log" >&2
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

for i in "${!UDIDS[@]}"; do
  UDID="${UDIDS[$i]}"
  PORT=$((8100 + i))
  MJPEG_PORT=$((9100 + i))
  LOG="${WORK}/wda-${PORT}.log"

  if wda_alive "$PORT"; then
    echo "WDA already running on :${PORT}"
    continue
  fi

  # ポートは per-sim の xctestrun コピーに環境変数として注入する（xcodebuild のプロセス env も併せて渡す）
  RUN_FILE="${WORK}/wda-${PORT}.xctestrun"
  cp "$XCTESTRUN" "$RUN_FILE"
  plist_set "$RUN_FILE" "${TARGET_KEY}:TestingEnvironmentVariables:USE_PORT" "$PORT"
  plist_set "$RUN_FILE" "${TARGET_KEY}:TestingEnvironmentVariables:MJPEG_SERVER_PORT" "$MJPEG_PORT"
  plist_set "$RUN_FILE" "${TARGET_KEY}:EnvironmentVariables:USE_PORT" "$PORT"
  plist_set "$RUN_FILE" "${TARGET_KEY}:EnvironmentVariables:MJPEG_SERVER_PORT" "$MJPEG_PORT"

  # test-without-building は WDA が動いている間ずっと走り続けるため、バックグラウンドで起動する
  USE_PORT="$PORT" MJPEG_SERVER_PORT="$MJPEG_PORT" nohup xcodebuild \
    test-without-building \
    -xctestrun "$RUN_FILE" \
    -destination "platform=iOS Simulator,id=${UDID}" >"$LOG" 2>&1 &
  echo "WDA launching: sim ${i} (${UDID}) -> :${PORT} / MJPEG :${MJPEG_PORT}"
done

echo "WDA の起動を待機中（1 台あたり最大 5 分）..."
for i in "${!UDIDS[@]}"; do
  PORT=$((8100 + i))
  ok=0
  for _ in $(seq 1 60); do
    if wda_alive "$PORT"; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" -ne 1 ]; then
    echo "WDA :${PORT} が 5 分以内に起動しなかった。ログ末尾:" >&2
    tail -n 200 "${WORK}/wda-${PORT}.log" >&2
    exit 1
  fi
  echo "WDA ready: http://127.0.0.1:${PORT}"
done
