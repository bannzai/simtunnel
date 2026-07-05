#!/bin/bash
# WebDriverAgent を Simulator 上で起動し、127.0.0.1:8100 が応答するまで待つ。
# ビルド成果物 (wda-dd/Build/Products) が復元されていれば test-without-building で即起動し、
# なければ WDA_REF を clone して build-for-testing でビルドする（成果物は workflow が cache 保存）。
# すでに :8100 が応答していればそのまま成功する（冪等）。
set -euo pipefail

UDID="${1:?usage: start-wda.sh <simulator-udid>}"
WDA_REF="${WDA_REF:-master}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
PRODUCTS="${ROOT}/wda-dd/Build/Products"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
LOG="${WORK}/wda.log"

if curl -s -m 2 http://127.0.0.1:8100/status >/dev/null; then
  echo "WDA already running"
  exit 0
fi

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
    -destination "platform=iOS Simulator,id=${UDID}" \
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

echo "xctestrun: ${XCTESTRUN}"
# test-without-building は WDA が動いている間ずっと走り続けるため、バックグラウンドで起動する
nohup xcodebuild \
  test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS Simulator,id=${UDID}" >"$LOG" 2>&1 &

echo "WDA の起動を待機中（最大 5 分）..."
for _ in $(seq 1 60); do
  if curl -s -m 2 http://127.0.0.1:8100/status >/dev/null; then
    echo "WDA ready: http://127.0.0.1:8100"
    exit 0
  fi
  sleep 5
done

echo "WDA が 5 分以内に起動しなかった。ログ末尾:" >&2
tail -n 200 "$LOG" >&2
exit 1
