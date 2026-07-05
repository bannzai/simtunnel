#!/bin/bash
# 指定名の iOS Simulator を起動し、UDID を GITHUB_ENV (SIMULATOR_UDID) に書き出す。
# 起動済みならそのまま成功する（冪等）。
set -euo pipefail

DEVICE_NAME="${1:?usage: boot-simulator.sh <device-name>}"

# 同名デバイスが複数ランタイムに存在するため、ランタイムキーの降順 = 最新 OS を優先する
UDID=$(xcrun simctl list devices available --json \
  | jq -r --arg name "$DEVICE_NAME" \
      '[.devices | to_entries | sort_by(.key) | reverse | .[] | select(.key | contains("iOS")) | .value[] | select(.name == $name)][0].udid // empty')

if [ -z "$UDID" ]; then
  echo "Simulator が見つからない: ${DEVICE_NAME}" >&2
  echo "利用可能なデバイス:" >&2
  xcrun simctl list devices available >&2
  exit 1
fi

echo "boot: ${DEVICE_NAME} (${UDID})"
# 未起動なら boot して完了まで待ち、起動済みなら即返る
xcrun simctl bootstatus "$UDID" -b

echo "SIMULATOR_UDID=${UDID}" >> "${GITHUB_ENV:-/dev/null}"
echo "booted: ${UDID}"
