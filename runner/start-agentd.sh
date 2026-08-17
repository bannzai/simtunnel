#!/bin/bash
# simtunnel-agentd (agentd.py) を起動し、:8200 が応答するまで待つ。
# bind は 127.0.0.1 のまま。tailnet への公開は bridge.sh 側で行う（WDA / serve-sim と同じ原則）。
# すでに応答していれば何もしない（冪等）。
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: start-agentd.sh <simulator-udid>..." >&2; exit 1; }
PORT="${SIMTUNNEL_AGENTD_PORT:-8200}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
LOG="${WORK}/agentd.log"
mkdir -p "$WORK"

agentd_alive() { curl -s -m 2 "http://127.0.0.1:${PORT}/status" >/dev/null; }

if agentd_alive; then
  echo "agentd already running on :${PORT}"
  exit 0
fi

SIMULATOR_UDIDS="$*" SIMTUNNEL_AGENTD_PORT="$PORT" \
  nohup python3 "$(dirname "$0")/agentd.py" >"$LOG" 2>&1 &

echo "agentd の起動を待機中（最大 1 分）..."
for _ in $(seq 1 30); do
  if agentd_alive; then
    echo "agentd ready: http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 2
done

echo "agentd が 1 分以内に起動しなかった。ログ末尾:" >&2
tail -n 100 "$LOG" >&2
exit 1
