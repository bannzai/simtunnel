#!/bin/bash
# EvanBacon/serve-sim を起動し、preview UI (:3200) と stream (:3100) が listen するまで待つ。
# preview UI はブラウザからの双方向操作 (タップ/スワイプ/キー入力等) を提供する。
# bind は 127.0.0.1 のまま（serve-sim は無認証 + shell-exec route を持つため）。
# tailnet への公開は bridge.sh 側で行う。
set -euo pipefail

UDID="${1:?usage: start-serve-sim.sh <simulator-udid>}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
LOG="${WORK}/serve-sim.log"

# serve-sim (Node) は localhost bind 時に ::1 側だけで listen することがあるため両方見る
port_open() {
  nc -z -w 2 127.0.0.1 "$1" >/dev/null 2>&1 || nc -z -w 2 ::1 "$1" >/dev/null 2>&1
}

if port_open 3200; then
  echo "serve-sim already running"
  exit 0
fi

nohup npx --yes serve-sim --host 127.0.0.1 "$UDID" >"$LOG" 2>&1 &

# stream (3100) はクライアント接続時に遅延起動する可能性があるため、readiness は preview UI (3200) のみ見る
echo "serve-sim の起動を待機中（最大 5 分）..."
for _ in $(seq 1 60); do
  if port_open 3200; then
    echo "serve-sim ready: preview :3200"
    if port_open 3100; then
      echo "stream :3100 も listen 中"
    else
      echo "stream :3100 は未 listen（遅延起動の可能性。bridge は張るので接続時に解決されれば動く）"
    fi
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ':(3100|3200)' || true
    exit 0
  fi
  sleep 5
done

echo "serve-sim が 5 分以内に起動しなかった。診断:" >&2
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null >&2 || true
echo "--- serve-sim ログ末尾:" >&2
tail -n 100 "$LOG" >&2
exit 1
