#!/bin/bash
# macOS アプリをビルドして .app のパスと bundle id を GITHUB_ENV に出力する。
# 2 系統に対応する:
#   1. SAMPLE_APP=true: リポジトリ内サンプル (macOSProject/build.sh) をビルド
#   2. BUILD_PROJECT 指定: caller repo の .xcodeproj / .xcworkspace を xcodebuild でビルド
# 出力（GITHUB_ENV）: MAC_APP_PATH（.app の絶対パス） / MAC_BUNDLE_ID
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

emit() {
  local app_path=$1 bundle_id=$2
  echo "MAC_APP_PATH=${app_path}" >> "${GITHUB_ENV:-/dev/stdout}"
  echo "MAC_BUNDLE_ID=${bundle_id}" >> "${GITHUB_ENV:-/dev/stdout}"
  echo "built: ${app_path} (${bundle_id})"
}

if [ "${SAMPLE_APP:-false}" = "true" ]; then
  # simtunnel（runner スクリプト）を checkout したディレクトリにサンプルがある
  SAMPLE_DIR="${ROOT}/simtunnel/macOSProject"
  [ -d "$SAMPLE_DIR" ] || SAMPLE_DIR="${ROOT}/macOSProject"
  "${SAMPLE_DIR}/build.sh"
  APP="${SAMPLE_DIR}/build/MacSample.app"
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP}/Contents/Info.plist")
  emit "$APP" "$BUNDLE_ID"
  exit 0
fi

PROJECT="${BUILD_PROJECT:?SAMPLE_APP=true でない場合は BUILD_PROJECT が必須}"
SCHEME="${BUILD_SCHEME:?BUILD_PROJECT 指定時は BUILD_SCHEME が必須}"
CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
DD="${ROOT}/macos-app-dd"

case "$PROJECT" in
  *.xcworkspace) CONTAINER=(-workspace "${ROOT}/${PROJECT}") ;;
  *) CONTAINER=(-project "${ROOT}/${PROJECT}") ;;
esac

xcodebuild \
  "${CONTAINER[@]}" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  -derivedDataPath "$DD" \
  -configuration "$CONFIGURATION" \
  build >"${WORK}/macos-app-build.log" 2>&1 || {
  echo "アプリのビルドに失敗。ログ末尾:" >&2
  tail -n 150 "${WORK}/macos-app-build.log" >&2
  exit 1
}

APP_PATH=$(find "${DD}/Build/Products/${CONFIGURATION}" -maxdepth 1 -name "*.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "ビルド後に .app が見つからない: ${DD}/Build/Products/${CONFIGURATION}" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")
emit "$APP_PATH" "$BUNDLE_ID"
