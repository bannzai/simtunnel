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

# --fail: HTTP 404 / 500 でも curl は exit 0 になるため、別プロセスがそのポートを
# 握っている状態を「起動できた」と誤判定しないよう、成功ステータスを必須にする
agentd_alive() { curl -fsS -m 2 "http://127.0.0.1:${PORT}/status" >/dev/null 2>&1; }

if agentd_alive; then
  echo "agentd already running on :${PORT}"
  exit 0
fi

SIMULATOR_UDIDS="$*" SIMTUNNEL_AGENTD_PORT="$PORT" \
  nohup python3 "$(dirname "$0")/agentd.py" >"$LOG" 2>&1 &
AGENTD_PID=$!

# curl のタイムアウト (2s) を含めると 1 ループ最大 4s のため、待機上限は実測どおり最大 2 分と案内する
echo "agentd の起動を待機中（最大 2 分）..."
for _ in $(seq 1 30); do
  if agentd_alive; then
    echo "agentd ready: http://127.0.0.1:${PORT}"
    exit 0
  fi
  # プロセスが即座に落ちた場合、生存確認なしだと失敗検知が待機上限まで遅れる
  if ! kill -0 "$AGENTD_PID" 2>/dev/null; then
    echo "agentd プロセスが終了した。ログ末尾:" >&2
    tail -n 100 "$LOG" >&2
    exit 1
  fi
  sleep 2
done

echo "agentd が 2 分以内に起動しなかった。ログ末尾:" >&2
tail -n 100 "$LOG" >&2
exit 1
