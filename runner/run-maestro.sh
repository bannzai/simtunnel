#!/bin/bash
# caller リポジトリに .maestro/flows/simtunnel/setup.yml があれば maestro で実行する（無ければスキップ）。
# オンボーディング等の定型突破を flow に任せ、以降の操作は WDA / MCP で行う想定。
# flow の失敗でセッションを潰さない（WDA 起動へ進む）ため、失敗は summary に警告を出して正常終了する。
set -euo pipefail

UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が未設定}"
FLOW=".maestro/flows/simtunnel/setup.yml"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

warn() {
  echo "::warning::$1"
  {
    echo "## ⚠️ Maestro flow"
    echo ""
    echo "$1"
  } >> "$SUMMARY"
}

if [ ! -f "$FLOW" ]; then
  echo "${FLOW} が無いためスキップ"
  exit 0
fi

# maestro は JVM で動く（Java 17+ 必須）。runner の既定 JAVA_HOME が古い場合に備えて新しい方へ向ける
for v in 21 17; do
  var="JAVA_HOME_${v}_arm64"
  if [ -n "${!var:-}" ]; then
    export JAVA_HOME="${!var}"
    break
  fi
done
java -version

export MAESTRO_CLI_NO_ANALYTICS=1
if ! curl -fsSL "https://get.maestro.mobile.dev" | bash; then
  warn "maestro CLI のインストールに失敗した。flow（\`${FLOW}\`）を実行せずセッションを開く。"
  exit 0
fi
export PATH="$PATH:$HOME/.maestro/bin"
maestro --version

if maestro --udid "$UDID" test "$FLOW"; then
  echo "maestro flow 成功: ${FLOW}"
  echo "- Maestro flow（\`${FLOW}\`）成功" >> "$SUMMARY"
else
  warn "flow（\`${FLOW}\`）の実行に失敗した。セッションはそのまま開く（アプリは flow 失敗時点の状態）。ログは step「Maestro flow を実行」を参照。"
fi
exit 0
