#!/bin/bash
# 指定時間だけジョブを維持する。WDA が応答しなくなったら維持する意味がないため終了する。
# 途中で止める場合はローカルから: gh run cancel <run-id> -R bannzai/simtunnel
set -euo pipefail

DURATION_MINUTES="${1:?usage: keepalive.sh <duration-minutes>}"
END=$(( $(date +%s) + DURATION_MINUTES * 60 ))

echo "セッション維持: ${DURATION_MINUTES} 分"
while [ "$(date +%s)" -lt "$END" ]; do
  if ! curl -s -m 5 http://127.0.0.1:8100/status >/dev/null; then
    echo "WDA が応答しなくなったためセッションを終了する" >&2
    exit 1
  fi
  sleep 30
done
echo "予定時間（${DURATION_MINUTES} 分）に達したためセッションを終了する"
