#!/bin/bash
# 引数で渡されたポート（省略時は 8100 9100）の 127.0.0.1 を tailscale インターフェースへ中継する。
# すでに tailscale インターフェースで listen しているポートは何もしない（冪等）。
set -euo pipefail

TS_IP="$(tailscale ip -4 | head -1)"
[ -n "$TS_IP" ] || { echo "tailscale IP が取得できない" >&2; exit 1; }
echo "tailscale IP: ${TS_IP}"

reachable() {
  local port=$1
  (echo -n > "/dev/tcp/${TS_IP}/${port}") >/dev/null 2>&1
}

ensure_bridge() {
  local port=$1
  if reachable "$port"; then
    echo "port ${port}: すでに ${TS_IP} で到達可能（bridge 不要）"
    return 0
  fi
  command -v socat >/dev/null 2>&1 || brew install socat
  nohup socat "TCP-LISTEN:${port},bind=${TS_IP},fork,reuseaddr" "TCP:127.0.0.1:${port}" >/dev/null 2>&1 &
  sleep 1
  reachable "$port" || { echo "port ${port}: bridge の起動に失敗" >&2; exit 1; }
  echo "port ${port}: bridged ${TS_IP}:${port} -> 127.0.0.1:${port}"
}

PORTS=("$@")
[ ${#PORTS[@]} -gt 0 ] || PORTS=(8100 9100)
for port in "${PORTS[@]}"; do
  ensure_bridge "$port"
done
