#!/bin/bash
# WebDriverAgent を Simulator 上でビルド・起動し、127.0.0.1:8100 が応答するまで待つ。
# すでに応答していればそのまま成功する（冪等）。
set -euo pipefail

UDID="${1:?usage: start-wda.sh <simulator-udid>}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
WDA_DIR="${WORK}/WebDriverAgent"
LOG="${WORK}/wda.log"

if curl -s -m 2 http://127.0.0.1:8100/status >/dev/null; then
  echo "WDA already running"
  exit 0
fi

if [ ! -d "$WDA_DIR" ]; then
  git clone --depth 1 https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
fi

(
  cd "$WDA_DIR"
  # xcodebuild test は WDA が動いている間ずっと走り続けるため、バックグラウンドで起動する
  nohup xcodebuild \
    -project WebDriverAgent.xcodeproj \
    -scheme WebDriverAgentRunner \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -derivedDataPath "${WORK}/wda-derived-data" \
    test >"$LOG" 2>&1 &
)

echo "WDA のビルドと起動を待機中（最大 15 分）..."
for _ in $(seq 1 180); do
  if curl -s -m 2 http://127.0.0.1:8100/status >/dev/null; then
    echo "WDA ready: http://127.0.0.1:8100"
    exit 0
  fi
  sleep 5
done

echo "WDA が 15 分以内に起動しなかった。ログ末尾:" >&2
tail -n 200 "$LOG" >&2
exit 1
