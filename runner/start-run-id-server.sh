#!/bin/bash
# agentd を持たないセッション（macOS）で、agentd と同じ :8200 の /status に run_id を返す受け口を起動する。
# ローカルの CLI は、ホスト名 simtunnel-<session> を名乗るノードが自分の dispatch した run のものかを
# この run_id で照合する（参照: PROJECT.md「MCP の登録」）。
# bind は 127.0.0.1 のまま。tailnet への公開は bridge.sh 側で行う（WDA / agentd と同じ原則）。
# すでに同じ run_id を返していれば何もしない（冪等）。
set -euo pipefail

PORT="${SIMTUNNEL_AGENTD_PORT:-8200}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}/run-id-server"
[ -n "${GITHUB_RUN_ID:-}" ] || { echo "GITHUB_RUN_ID が未設定" >&2; exit 1; }

serving_run_id() {
  curl -fsS -m 2 "http://127.0.0.1:${PORT}/status" 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("run_id", ""))' 2>/dev/null
}

if [ "$(serving_run_id || true)" = "$GITHUB_RUN_ID" ]; then
  echo "run_id server already running on :${PORT}"
  exit 0
fi

mkdir -p "$WORK"
printf '{"ok": true, "run_id": "%s"}\n' "$GITHUB_RUN_ID" >"${WORK}/status"
nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" >"${WORK}.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 15); do
  if [ "$(serving_run_id || true)" = "$GITHUB_RUN_ID" ]; then
    echo "run_id server ready: http://127.0.0.1:${PORT}/status"
    exit 0
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "run_id server が終了した。ログ末尾:" >&2
    tail -n 50 "${WORK}.log" >&2
    exit 1
  fi
  sleep 2
done

echo "run_id server が 30 秒以内に応答しなかった" >&2
exit 1
