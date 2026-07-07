#!/bin/bash
# 指定時間だけジョブを維持する。全 WDA が応答しなくなったら維持する意味がないため終了する。
# 高負荷時の一時的なストールを殺さないよう、ポートごとに連続 MAX_FAILS 回失敗した時だけ停止と判定する。
# 途中で止める場合はローカルから: gh run cancel <run-id> -R <workflow を動かしている repo>
# usage: keepalive.sh <duration-minutes> [wda-port...]（ポート省略時は 8100）
set -euo pipefail

DURATION_MINUTES="${1:?usage: keepalive.sh <duration-minutes> [wda-port...]}"
shift || true
PORTS=("$@")
[ ${#PORTS[@]} -gt 0 ] || PORTS=(8100)
END=$(( $(date +%s) + DURATION_MINUTES * 60 ))
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
MAX_FAILS=4

FAILS=()
for _ in "${PORTS[@]}"; do FAILS+=(0); done

echo "セッション維持: ${DURATION_MINUTES} 分 (WDA ports: ${PORTS[*]})"
while [ "$(date +%s)" -lt "$END" ]; do
  alive=0
  for idx in "${!PORTS[@]}"; do
    port=${PORTS[$idx]}
    # 停止判定済みのポートは再チェックしない
    if [ "${FAILS[$idx]}" -ge "$MAX_FAILS" ]; then continue; fi
    if curl -s -m 10 "http://127.0.0.1:${port}/status" >/dev/null; then
      FAILS[$idx]=0
      alive=1
    else
      FAILS[$idx]=$((FAILS[$idx] + 1))
      echo "WDA :${port} 無応答 (${FAILS[$idx]}/${MAX_FAILS}) $(date '+%H:%M:%S')" >&2
      if [ "${FAILS[$idx]}" -ge "$MAX_FAILS" ]; then
        echo "WDA :${port} を停止と判定" >&2
        # 原因調査用に WDA のログ末尾を残す（start-wda.sh と同じログパス）
        if [ -f "${WORK}/wda-${port}.log" ]; then
          echo "--- wda-${port}.log 末尾 ---" >&2
          tail -n 60 "${WORK}/wda-${port}.log" >&2
        fi
      else
        alive=1
      fi
    fi
  done
  if [ "$alive" -eq 0 ]; then
    echo "全 WDA が応答しなくなったためセッションを終了する" >&2
    exit 1
  fi
  sleep 15
done
echo "予定時間（${DURATION_MINUTES} 分）に達したためセッションを終了する"
