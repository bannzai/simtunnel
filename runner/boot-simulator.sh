#!/bin/bash
# 指定名の iOS Simulator を COUNT 台起動し、UDID を GITHUB_ENV に書き出す
# (SIMULATOR_UDID = 1 台目 / SIMULATOR_UDIDS = 全台のスペース区切り)。
# 2 台目以降は基準デバイスの clone（"<name> simtunnel-<i>"）を使う。
# 起動済み・clone 済みならそのまま使う（冪等）。
set -euo pipefail

DEVICE_NAME="${1:?usage: boot-simulator.sh <device-name> [count]}"
COUNT="${2:-1}"
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 1 ] || { echo "simulators は 1 以上の整数: $COUNT" >&2; exit 1; }

find_device() {
  # 同名デバイスが複数ランタイムに存在するため、ランタイムキーの降順 = 最新 OS を優先する
  xcrun simctl list devices available --json \
    | jq -r --arg name "$1" \
        '[.devices | to_entries | sort_by(.key) | reverse | .[] | select(.key | contains("iOS")) | .value[] | select(.name == $name)][0].udid // empty'
}

BASE_UDID=$(find_device "$DEVICE_NAME")
if [ -z "$BASE_UDID" ]; then
  echo "Simulator が見つからない: ${DEVICE_NAME}" >&2
  echo "利用可能なデバイス:" >&2
  xcrun simctl list devices available >&2
  exit 1
fi

UDIDS=("$BASE_UDID")
# BSD seq は `seq 2 1` が逆順（2 1）を返すため、COUNT=1 ではループ自体を実行しない
if [ "$COUNT" -ge 2 ]; then
  for i in $(seq 2 "$COUNT"); do
    CLONE_NAME="${DEVICE_NAME} simtunnel-${i}"
    CLONE_UDID=$(find_device "$CLONE_NAME")
    if [ -z "$CLONE_UDID" ]; then
      CLONE_UDID=$(xcrun simctl clone "$BASE_UDID" "$CLONE_NAME")
      echo "cloned: ${CLONE_NAME} (${CLONE_UDID})"
    fi
    UDIDS+=("$CLONE_UDID")
  done
fi

[ "${#UDIDS[@]}" -eq "$COUNT" ] || {
  echo "起動対象の台数が simulators=${COUNT} と一致しない: ${UDIDS[*]}" >&2
  exit 1
}

for u in "${UDIDS[@]}"; do
  echo "boot: ${u}"
  # 未起動なら boot して完了まで待ち、起動済みなら即返る
  xcrun simctl bootstatus "$u" -b
done

{
  echo "SIMULATOR_UDID=${UDIDS[0]}"
  echo "SIMULATOR_UDIDS=${UDIDS[*]}"
} >> "${GITHUB_ENV:-/dev/null}"
echo "booted: ${UDIDS[*]}"
