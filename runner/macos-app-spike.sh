#!/bin/bash
# macOS アプリ対応の go/no-go スパイク (issue #23)。
# macos-26 runner 上で以下が通るかを実測し、証跡を SPIKE RESULT にまとめる:
#   1. TCC: 画面収録 (kTCCServiceScreenCapture) とアクセシビリティ (kTCCServiceAccessibility) の付与
#   2. screencapture CLI で実際のウィンドウ内容が撮れるか (壁紙だけでないか)
#   3. WebDriverAgentMac (appium-mac2-driver 同梱) の build-for-testing → 起動 → /status
#   4. WDA 経由の screenshot / source (アクセシビリティツリー) / click
# 各チェックは失敗しても継続し、全証跡を集めてから overall を判定する (だから set -e は使わない)。
set -uo pipefail

MAC2_REF="${MAC2_REF:-v4.1.1}"
WDA_PORT="${WDA_PORT:-10100}"
WDA_HOST=127.0.0.1
TARGET_BUNDLE_ID="${TARGET_BUNDLE_ID:-com.apple.TextEdit}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
RESULTS=()

# チェック結果を 1 行記録する。status は OK / NG / INFO
record() {
  local status=$1 name=$2 detail=$3
  RESULTS+=("${status}|${name}|${detail}")
  echo "[${status}] ${name}: ${detail}"
}

section() { echo ""; echo "======== $1 ========"; }

# ---- 0. 環境情報 ----
section "environment"
sw_vers || true
xcodebuild -version || true
echo "python3: $(command -v python3 || echo none)"
echo "sqlite3: $(command -v sqlite3 || echo none)"

# ---- 1. TCC 付与 ----
section "TCC grant"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"

dump_tcc() {
  local db=$1
  sudo sqlite3 "$db" \
    "SELECT service, client, auth_value FROM access WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceAccessibility');" \
    2>&1 || echo "(read failed)"
}

echo "--- system TCC.db (before) ---"
dump_tcc "$SYS_TCC"

# 既存行 (provisioner 等) を allowed(2) に更新する。runner-images issue #8782 の指摘どおり
# auth_value 列を許可へ倒すのが実効的な修正。SIP で失敗しうるため成否を記録する。
if sudo sqlite3 "$SYS_TCC" \
    "UPDATE access SET auth_value=2 WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceAccessibility');" 2>"${WORK}/tcc-update.err"; then
  record OK tcc-system-update "system TCC.db の既存行を auth_value=2 に更新できた"
else
  record NG tcc-system-update "system TCC.db 更新に失敗: $(tr '\n' ' ' <"${WORK}/tcc-update.err")"
fi

echo "--- system TCC.db (after) ---"
dump_tcc "$SYS_TCC"

# xcodebuild/testmanagerd が使う可能性のあるバイナリへも付与を試みる (存在すれば)。
for bin in /usr/sbin/screencapture /bin/bash; do
  sudo sqlite3 "$SYS_TCC" \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('kTCCServiceScreenCapture','${bin}',1,2,4,1,0);" \
    2>/dev/null && echo "granted screencapture -> ${bin}" || echo "grant skipped -> ${bin} (schema mismatch?)"
done

# ---- 2. screencapture CLI ----
section "screencapture CLI"
# 比較用の 32px 中央クロップ md5 を返す。壁紙のみ vs ウィンドウありで差が出るかを見る。
crop_md5() {
  local png=$1 out="${png}.thumb.png"
  cp "$png" "$out"
  sips -c 400 400 "$out" >/dev/null 2>&1 || true   # 中央 400x400 にクロップ
  sips -Z 32 "$out" >/dev/null 2>&1 || true         # 32px に縮小
  md5 -q "$out" 2>/dev/null || md5sum "$out" | awk '{print $1}'
}

BEFORE_PNG="${WORK}/cap-before.png"
AFTER_PNG="${WORK}/cap-after.png"

screencapture -x "$BEFORE_PNG" 2>"${WORK}/cap-before.err"
if [ -s "$BEFORE_PNG" ]; then
  record INFO screencapture-baseline "壁紙のみ想定のベースライン取得 ($(stat -f%z "$BEFORE_PNG" 2>/dev/null || stat -c%s "$BEFORE_PNG") bytes)"
else
  record NG screencapture-baseline "ベースライン取得に失敗: $(tr '\n' ' ' <"${WORK}/cap-before.err")"
fi

# 中央に見分けのつくウィンドウを出す。TextEdit を全画面近くまで広げて文字を入れる。
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || echo "osascript(TextEdit) failed"
tell application "TextEdit"
  activate
  make new document
  set text of front document to "SIMTUNNEL SPIKE WINDOW CONTENT CHECK 1234567890"
end tell
delay 2
tell application "System Events"
  tell process "TextEdit"
    try
      set position of front window to {100, 100}
      set size of front window to {1200, 800}
    end try
  end tell
end tell
APPLESCRIPT
sleep 2

screencapture -x "$AFTER_PNG" 2>"${WORK}/cap-after.err"
if [ -s "$AFTER_PNG" ]; then
  B_MD5=$(crop_md5 "$BEFORE_PNG")
  A_MD5=$(crop_md5 "$AFTER_PNG")
  echo "center-crop md5 before=${B_MD5} after=${A_MD5}"
  if [ -n "$A_MD5" ] && [ "$A_MD5" != "$B_MD5" ]; then
    record OK screencapture-content "TextEdit を開くと中央クロップが変化 → 実ウィンドウ内容が撮れている"
  else
    record NG screencapture-content "ウィンドウを開いても中央クロップが不変 → 壁紙のみ (画面収録が効いていない疑い)"
  fi
else
  record NG screencapture-content "ウィンドウ表示後のキャプチャに失敗: $(tr '\n' ' ' <"${WORK}/cap-after.err")"
fi

# ---- 3. WebDriverAgentMac をビルドして起動 ----
section "WebDriverAgentMac build & launch"
SRC="${WORK}/appium-mac2-driver"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$MAC2_REF" https://github.com/appium/appium-mac2-driver.git "$SRC" 2>"${WORK}/clone.err" \
    && record OK mac2-clone "appium-mac2-driver ${MAC2_REF} を clone した" \
    || record NG mac2-clone "clone 失敗: $(tr '\n' ' ' <"${WORK}/clone.err")"
fi
WDA_PROJ="${SRC}/WebDriverAgentMac/WebDriverAgentMac.xcodeproj"

WDA_LOG="${WORK}/wdamac.log"
WDA_ALIVE=0
if [ -d "$WDA_PROJ" ]; then
  # lib/wda-mac.ts と同じ起動方法: build-for-testing test-without-building + USE_PORT/USE_HOST。
  # test-without-building は起動中ずっと走り続けるためバックグラウンド化する。
  USE_PORT="$WDA_PORT" USE_HOST="$WDA_HOST" nohup xcodebuild \
    build-for-testing test-without-building \
    -project "$WDA_PROJ" \
    -scheme WebDriverAgentRunner \
    -destination "platform=macOS" \
    COMPILER_INDEX_STORE_ENABLE=NO >"$WDA_LOG" 2>&1 &
  echo "WDAMac launching -> http://${WDA_HOST}:${WDA_PORT} (最大 20 分待つ)"
  for _ in $(seq 1 120); do
    if curl -s -m 3 "http://${WDA_HOST}:${WDA_PORT}/status" >/dev/null 2>&1; then WDA_ALIVE=1; break; fi
    sleep 10
  done
  if [ "$WDA_ALIVE" -eq 1 ]; then
    record OK wdamac-status "WDAMac が起動し /status が応答した"
    curl -s -m 5 "http://${WDA_HOST}:${WDA_PORT}/status" | tee "${WORK}/status.json"; echo ""
  else
    record NG wdamac-status "WDAMac が 20 分以内に /status を返さなかった。ログ末尾は後段に出力"
  fi
else
  record NG wdamac-status "WebDriverAgentMac.xcodeproj が見つからない: ${WDA_PROJ}"
fi

# ---- 4. WDA 経由の操作 ----
section "WDA operations"
BASE="http://${WDA_HOST}:${WDA_PORT}"
if [ "$WDA_ALIVE" -eq 1 ]; then
  # screenshot (session 不要)
  SS_JSON="${WORK}/screenshot.json"
  if curl -s -m 30 "${BASE}/screenshot" -o "$SS_JSON" && [ -s "$SS_JSON" ]; then
    SS_B64=$(jq -r '.value // empty' "$SS_JSON")
    if [ -n "$SS_B64" ]; then
      echo "$SS_B64" | base64 -D >"${WORK}/wda-screenshot.png" 2>/dev/null || echo "$SS_B64" | base64 -d >"${WORK}/wda-screenshot.png"
      SS_SIZE=$(stat -f%z "${WORK}/wda-screenshot.png" 2>/dev/null || stat -c%s "${WORK}/wda-screenshot.png")
      if [ "${SS_SIZE:-0}" -gt 10000 ]; then
        record OK wda-screenshot "WDA /screenshot が PNG を返した (${SS_SIZE} bytes)"
      else
        record NG wda-screenshot "WDA /screenshot が小さすぎる (${SS_SIZE} bytes) → 中身が空の疑い"
      fi
    else
      record NG wda-screenshot "WDA /screenshot の value が空: $(head -c 200 "$SS_JSON")"
    fi
  else
    record NG wda-screenshot "WDA /screenshot 呼び出しに失敗"
  fi

  # session 作成 (対象アプリを launch)
  SESS_JSON="${WORK}/session.json"
  curl -s -m 60 -X POST "${BASE}/session" \
    -H 'Content-Type: application/json' \
    -d "{\"capabilities\":{\"alwaysMatch\":{\"platformName\":\"mac\",\"appium:bundleId\":\"${TARGET_BUNDLE_ID}\"}}}" \
    -o "$SESS_JSON" 2>/dev/null
  SESSION_ID=$(jq -r '.value.sessionId // .sessionId // empty' "$SESS_JSON" 2>/dev/null)
  if [ -n "$SESSION_ID" ]; then
    record OK wda-session "session 作成成功 (${TARGET_BUNDLE_ID}) id=${SESSION_ID}"
  else
    record NG wda-session "session 作成失敗: $(head -c 300 "$SESS_JSON")"
  fi

  # source (アクセシビリティツリー)
  SRC_JSON="${WORK}/source.json"
  if curl -s -m 30 "${BASE}/source?format=json" -o "$SRC_JSON" && [ -s "$SRC_JSON" ]; then
    NODE_COUNT=$(jq '[.. | objects] | length' "$SRC_JSON" 2>/dev/null || echo 0)
    if [ "${NODE_COUNT:-0}" -gt 1 ]; then
      record OK wda-source "アクセシビリティツリー取得 (${NODE_COUNT} ノード)"
    else
      record NG wda-source "source のノード数が不足 (${NODE_COUNT}): $(head -c 200 "$SRC_JSON")"
    fi
  else
    record NG wda-source "source 呼び出しに失敗"
  fi

  # click (W3C pointer actions)。session があればそこへ、無ければ全画面座標へ。
  if [ -n "$SESSION_ID" ]; then
    CLICK_URL="${BASE}/session/${SESSION_ID}/actions"
  else
    CLICK_URL="${BASE}/actions"
  fi
  CLICK_JSON="${WORK}/click.json"
  HTTP_CODE=$(curl -s -m 30 -o "$CLICK_JSON" -w '%{http_code}' -X POST "$CLICK_URL" \
    -H 'Content-Type: application/json' \
    -d '{"actions":[{"type":"pointer","id":"mouse","parameters":{"pointerType":"mouse"},"actions":[{"type":"pointerMove","duration":0,"x":300,"y":300},{"type":"pointerDown","button":0},{"type":"pause","duration":100},{"type":"pointerUp","button":0}]}]}' 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    record OK wda-click "W3C actions click が HTTP 200 で成功"
  else
    record NG wda-click "click が HTTP ${HTTP_CODE}: $(head -c 300 "$CLICK_JSON")"
  fi

  [ -n "$SESSION_ID" ] && curl -s -m 10 -X DELETE "${BASE}/session/${SESSION_ID}" >/dev/null 2>&1 || true
else
  record NG wda-operations "WDA 未起動のため screenshot/source/click は未検証"
fi

# WDA ログ末尾を常に出す (署名・TCC 起因の失敗を掴むため)
section "WDAMac log tail"
[ -f "$WDA_LOG" ] && tail -n 120 "$WDA_LOG" || echo "(no log)"

# ---- SPIKE RESULT ----
section "SPIKE RESULT"
NG_COUNT=0
{
  echo "## macOS アプリ対応スパイク結果 (issue #23)"
  echo ""
  echo "| status | check | detail |"
  echo "|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r st nm dt <<<"$r"
    [ "$st" = "NG" ] && NG_COUNT=$((NG_COUNT + 1))
    echo "| ${st} | ${nm} | ${dt} |"
  done
  echo ""
  if [ "$NG_COUNT" -eq 0 ]; then
    echo "**overall: GO** — 全チェック成功"
  else
    echo "**overall: 要判断** — NG ${NG_COUNT} 件 (ログ全文で切り分けること)"
  fi
} | tee -a "$SUMMARY"

# runner ジョブ自体は「スパイクが最後まで走った」ことを成功とし、go/no-go は SPIKE RESULT で判断する。
exit 0
