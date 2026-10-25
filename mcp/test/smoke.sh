#!/usr/bin/env bash
# simtunnel-mcp の起動と MCP の initialize 応答を確認する smoke test。
# WDA には接続しないため、SIMTUNNEL_WDA_URL はダミーでよい。
# サーバは stdin の EOF で終了するため、timeout は要らない。
# 使い方: bash mcp/test/smoke.sh  (mcp/ で npm ci 済みであること)
set -euo pipefail

cd "$(dirname "$0")/.."

node --check index.mjs

request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
response=$(printf '%s\n' "$request" | SIMTUNNEL_WDA_URL=http://127.0.0.1:1 node index.mjs)

if ! printf '%s' "$response" | grep -q '"serverInfo"'; then
  echo "initialize の応答に serverInfo が無い。応答: ${response}" >&2
  exit 1
fi
echo "ok: initialize の応答を受信した"
