#!/bin/bash
# サンプル macOS アプリ (MacSample.app) を swiftc でビルドして .app バンドルに組み立てる。
# Xcode プロジェクトを持たない最小構成のため、ビルドは数秒で終わる。
# 出力: macOSProject/build/MacSample.app（既存があれば作り直す = 冪等）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="${DIR}/build"
APP="${BUILD}/MacSample.app"

rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

swiftc -O -parse-as-library "${DIR}/MacSampleApp.swift" -o "${APP}/Contents/MacOS/MacSample"
cp "${DIR}/Info.plist" "${APP}/Contents/Info.plist"

# ad-hoc 署名（未署名だと Gatekeeper / AMFI に起動を拒否されることがある）
codesign --force -s - "$APP"

echo "built: ${APP}"
