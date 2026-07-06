#!/bin/bash
# 指定時間だけジョブを維持する。WDA が応答しなくなったら維持する意味がないため終了する。
# 高負荷時の一時的なストールを殺さないよう、連続 MAX_FAILS 回失敗した時だけ終了する。
# 途中で止める場合はローカルから: gh run cancel <run-id> -R <workflow を動かしている repo>
set -euo pipefail

DURATION_MINUTES="${1:?usage: keepalive.sh <duration-minutes>}"
END=$(( $(date +%s) + DURATION_MINUTES * 60 ))
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
FAILS=0
MAX_FAILS=4

echo "セッション維持: ${DURATION_MINUTES} 分"
while [ "$(date +%s)" -lt "$END" ]; do
  if curl -s -m 10 http://127.0.0.1:8100/status >/dev/null; then
    FAILS=0
  else
    FAILS=$((FAILS + 1))
    echo "WDA 無応答 (${FAILS}/${MAX_FAILS}) $(date '+%H:%M:%S')" >&2
    if [ "$FAILS" -ge "$MAX_FAILS" ]; then
      echo "WDA が応答しなくなったためセッションを終了する" >&2
      # 原因調査用に WDA のログ末尾を残す（start-wda.sh と同じログパス）
      if [ -f "${WORK}/wda.log" ]; then
        echo "--- wda.log 末尾 ---" >&2
        tail -n 60 "${WORK}/wda.log" >&2
      fi
      exit 1
    fi
  fi
  sleep 15
done
echo "予定時間（${DURATION_MINUTES} 分）に達したためセッションを終了する"
