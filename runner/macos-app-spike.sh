#!/bin/bash
# macOS アプリ対応の go/no-go スパイク (issue #23)。使い捨て・検証専用。
# macos-26 runner 上で以下を実測し、証跡 (スクショ等) を SPIKE_OUT に集めて artifact に上げる:
#   1. TCC: 画面収録 (kTCCServiceScreenCapture) とアクセシビリティ (kTCCServiceAccessibility) の状態
#   2. screencapture CLI で実ウィンドウ内容が撮れるか (壁紙だけでないか)
#   3. WebDriverAgentMac (appium-mac2-driver 同梱) の build-for-testing → 起動 → /status
#   4. WDA 経由の screenshot / source / キー入力 / 座標クリック / W3C actions
#   5. Calculator にキーを打ち、スクショの中央クロップが変化する = 実際にアプリを操作できている証跡
# 各チェックは失敗しても継続し、全証跡を集めてから overall を判定する (だから set -e は使わない)。
set -uo pipefail

MAC2_REF="${MAC2_REF:-v4.1.1}"
WDA_PORT="${WDA_PORT:-10100}"
WDA_HOST=127.0.0.1
TARGET_BUNDLE_ID="${TARGET_BUNDLE_ID:-com.apple.calculator}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
SPIKE_OUT="${GITHUB_WORKSPACE:-$(pwd)}/spike-out"
mkdir -p "$WORK" "$SPIKE_OUT"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
RESULTS=()

record() {
  local status=$1 name=$2 detail=$3
  RESULTS+=("${status}|${name}|${detail}")
  echo "[${status}] ${name}: ${detail}"
}
section() { echo ""; echo "======== $1 ========"; }

# 画像の中央 400x400 を 32px に縮小した md5。壁紙のみ vs ウィンドウあり / 操作前 vs 後の差分検出に使う。
crop_md5() {
  local png=$1 out="${WORK}/$(basename "$png").thumb.png"
  cp "$png" "$out" 2>/dev/null || return 0
  sips -c 400 400 "$out" >/dev/null 2>&1 || true
  sips -Z 32 "$out" >/dev/null 2>&1 || true
  md5 -q "$out" 2>/dev/null || md5sum "$out" 2>/dev/null | awk '{print $1}'
}
png_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# WDA の screenshot を SPIKE_OUT に保存し、bytes を返す (取得失敗なら 0)。
wda_screenshot() {
  local out=$1 json="${WORK}/ss.json"
  curl -s -m 30 "http://${WDA_HOST}:${WDA_PORT}/screenshot" -o "$json" || return 1
  local b64; b64=$(jq -r '.value // empty' "$json" 2>/dev/null)
  [ -n "$b64" ] || return 1
  echo "$b64" | base64 -D >"$out" 2>/dev/null || echo "$b64" | base64 -d >"$out"
  png_size "$out"
}

# ---- 0. 環境情報 ----
section "environment"
sw_vers || true
xcodebuild -version || true

# ---- 1. TCC 状態と付与 ----
section "TCC grant"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
dump_tcc() {
  sudo sqlite3 "$SYS_TCC" \
    "SELECT service, client, auth_value FROM access WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceAccessibility');" 2>&1 || echo "(read failed)"
}
echo "--- system TCC.db (before) ---"; dump_tcc | tee "${SPIKE_OUT}/tcc-before.txt"
if sudo sqlite3 "$SYS_TCC" \
    "UPDATE access SET auth_value=2 WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceAccessibility');" 2>"${WORK}/tcc.err"; then
  record OK tcc-update "TCC.db の既存行を auth_value=2 (allowed) に更新できた"
else
  record NG tcc-update "TCC.db 更新に失敗: $(tr '\n' ' ' <"${WORK}/tcc.err")"
fi
echo "--- system TCC.db (after) ---"; dump_tcc | tee "${SPIKE_OUT}/tcc-after.txt"
# accessibility が Xcode-Helper に付与済みかを明示的に判定 (XCTest 操作の前提)
if dump_tcc | grep -q "kTCCServiceAccessibility|com.apple.dt.Xcode-Helper|2"; then
  record OK tcc-accessibility "kTCCServiceAccessibility が com.apple.dt.Xcode-Helper に付与済み"
else
  record NG tcc-accessibility "Xcode-Helper への accessibility 付与が確認できない"
fi

# ---- 2. screencapture CLI (issue の go/no-go 項目) ----
section "screencapture CLI"
screencapture -x "${SPIKE_OUT}/cli-before.png" 2>/dev/null
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "TextEdit"
  activate
  make new document
  set text of front document to "SIMTUNNEL SPIKE WINDOW 1234567890"
end tell
delay 2
APPLESCRIPT
sleep 2
screencapture -x "${SPIKE_OUT}/cli-after.png" 2>/dev/null
osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
if [ -s "${SPIKE_OUT}/cli-after.png" ]; then
  if [ "$(crop_md5 "${SPIKE_OUT}/cli-before.png")" != "$(crop_md5 "${SPIKE_OUT}/cli-after.png")" ]; then
    record OK screencapture-content "screencapture CLI がウィンドウ内容を撮れている (中央クロップが変化)"
  else
    record NG screencapture-content "screencapture CLI は壁紙のみ (中央クロップ不変)。WDA 経路で代替する"
  fi
else
  record NG screencapture-content "screencapture CLI のキャプチャに失敗"
fi

# ---- 3. WebDriverAgentMac ビルド & 起動 ----
section "WebDriverAgentMac build & launch"
SRC="${WORK}/appium-mac2-driver"
[ -d "$SRC" ] || git clone --depth 1 --branch "$MAC2_REF" https://github.com/appium/appium-mac2-driver.git "$SRC" 2>"${WORK}/clone.err"
WDA_PROJ="${SRC}/WebDriverAgentMac/WebDriverAgentMac.xcodeproj"
WDA_LOG="${WORK}/wdamac.log"
WDA_ALIVE=0
if [ -d "$WDA_PROJ" ]; then
  record OK mac2-clone "appium-mac2-driver ${MAC2_REF} を取得した"
  USE_PORT="$WDA_PORT" USE_HOST="$WDA_HOST" nohup xcodebuild \
    build-for-testing test-without-building \
    -project "$WDA_PROJ" -scheme WebDriverAgentRunner -destination "platform=macOS" \
    COMPILER_INDEX_STORE_ENABLE=NO >"$WDA_LOG" 2>&1 &
  echo "WDAMac launching -> http://${WDA_HOST}:${WDA_PORT} (最大 20 分待つ)"
  for _ in $(seq 1 120); do
    curl -s -m 3 "http://${WDA_HOST}:${WDA_PORT}/status" >/dev/null 2>&1 && { WDA_ALIVE=1; break; }
    sleep 10
  done
  if [ "$WDA_ALIVE" -eq 1 ]; then
    curl -s -m 5 "http://${WDA_HOST}:${WDA_PORT}/status" -o "${SPIKE_OUT}/status.json"
    record OK wdamac-status "WDAMac が起動し /status が応答した"
  else
    record NG wdamac-status "WDAMac が 20 分以内に /status を返さなかった"
  fi
else
  record NG mac2-clone "clone 失敗: $(tr '\n' ' ' <"${WORK}/clone.err" 2>/dev/null)"
fi
tail -n 60 "$WDA_LOG" >"${SPIKE_OUT}/wdamac-log-tail.txt" 2>/dev/null || true

# ---- 4. WDA 経由の操作 ----
section "WDA operations (Calculator)"
BASE="http://${WDA_HOST}:${WDA_PORT}"
if [ "$WDA_ALIVE" -eq 1 ]; then
  # session 不要の screenshot がまず取れるか
  SS0=$(wda_screenshot "${SPIKE_OUT}/wda-0-nosession.png" || echo 0)
  [ "${SS0:-0}" -gt 10000 ] \
    && record OK wda-screenshot "WDA /screenshot が PNG を返した (${SS0} bytes / 画像は artifact で確認)" \
    || record NG wda-screenshot "WDA /screenshot が空か小さすぎる (${SS0} bytes)"

  # session 作成 (Calculator を launch)
  curl -s -m 60 -X POST "${BASE}/session" -H 'Content-Type: application/json' \
    -d "{\"capabilities\":{\"alwaysMatch\":{\"platformName\":\"mac\",\"appium:bundleId\":\"${TARGET_BUNDLE_ID}\"}}}" \
    -o "${SPIKE_OUT}/session.json" 2>/dev/null
  SID=$(jq -r '.value.sessionId // .sessionId // empty' "${SPIKE_OUT}/session.json" 2>/dev/null)
  [ -n "$SID" ] \
    && record OK wda-session "session 作成成功 (${TARGET_BUNDLE_ID}) id=${SID}" \
    || record NG wda-session "session 作成失敗: $(head -c 300 "${SPIKE_OUT}/session.json")"
  sleep 2

  if [ -n "$SID" ]; then
    # session スコープの source (アプリのアクセシビリティツリー)
    curl -s -m 30 "${BASE}/session/${SID}/source?format=json" -o "${SPIKE_OUT}/source.json" 2>/dev/null
    NODES=$(jq '[.. | objects] | length' "${SPIKE_OUT}/source.json" 2>/dev/null || echo 0)
    [ "${NODES:-0}" -gt 10 ] \
      && record OK wda-source "アプリのアクセシビリティツリー取得 (${NODES} ノード)" \
      || record NG wda-source "source のノード数が少ない (${NODES})。artifact の source.json を確認"

    # 操作前スクショ → キー入力 (5, +, 3, =) → 操作後スクショ。中央クロップの変化で操作成立を判定。
    wda_screenshot "${SPIKE_OUT}/wda-1-before-keys.png" >/dev/null
    KEYS_CODE=$(curl -s -m 30 -o "${SPIKE_OUT}/keys.json" -w '%{http_code}' -X POST "${BASE}/session/${SID}/wda/keys" \
      -H 'Content-Type: application/json' -d '{"keys":["5","+","3","="]}' 2>/dev/null)
    sleep 1
    wda_screenshot "${SPIKE_OUT}/wda-2-after-keys.png" >/dev/null
    if [ "$KEYS_CODE" = "200" ]; then
      if [ "$(crop_md5 "${SPIKE_OUT}/wda-1-before-keys.png")" != "$(crop_md5 "${SPIKE_OUT}/wda-2-after-keys.png")" ]; then
        record OK wda-keys "キー入力後にスクショ中央が変化 → アプリを操作できている (5+3= を Calculator に入力)"
      else
        record NG wda-keys "キー入力は 200 だがスクショが不変。artifact の before/after を確認"
      fi
    else
      record NG wda-keys "キー入力が HTTP ${KEYS_CODE}: $(head -c 200 "${SPIKE_OUT}/keys.json")"
    fi

    # 座標クリック (/wda/click は currentApplication 相対座標)
    CLICK_CODE=$(curl -s -m 30 -o "${SPIKE_OUT}/click.json" -w '%{http_code}' -X POST "${BASE}/session/${SID}/wda/click" \
      -H 'Content-Type: application/json' -d '{"x":100,"y":120}' 2>/dev/null)
    [ "$CLICK_CODE" = "200" ] \
      && record OK wda-click "座標クリック (/wda/click) が HTTP 200" \
      || record NG wda-click "座標クリックが HTTP ${CLICK_CODE}: $(head -c 200 "${SPIKE_OUT}/click.json")"

    # W3C actions (mobile-mcp 互換レイヤーが使う経路。エラー詳細を artifact に残す)
    ACT_CODE=$(curl -s -m 30 -o "${SPIKE_OUT}/actions.json" -w '%{http_code}' -X POST "${BASE}/session/${SID}/actions" \
      -H 'Content-Type: application/json' \
      -d '{"actions":[{"type":"pointer","id":"mouse","parameters":{"pointerType":"mouse"},"actions":[{"type":"pointerMove","duration":0,"x":100,"y":120},{"type":"pointerDown","button":0},{"type":"pause","duration":50},{"type":"pointerUp","button":0}]}]}' 2>/dev/null)
    [ "$ACT_CODE" = "200" ] \
      && record OK wda-actions "W3C actions が HTTP 200" \
      || record NG wda-actions "W3C actions が HTTP ${ACT_CODE}: $(head -c 200 "${SPIKE_OUT}/actions.json")"

    curl -s -m 10 -X DELETE "${BASE}/session/${SID}" >/dev/null 2>&1 || true
  fi
else
  record NG wda-operations "WDA 未起動のため screenshot/source/keys/click は未検証"
fi

# ---- SPIKE RESULT ----
section "SPIKE RESULT"
NG_COUNT=0
{
  echo "## macOS アプリ対応スパイク結果 (issue #23)"
  echo ""
  echo "スクリーンショット等の証跡は artifact \`macos-app-spike\` を参照。"
  echo ""
  echo "| status | check | detail |"
  echo "|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r st nm dt <<<"$r"
    [ "$st" = "NG" ] && NG_COUNT=$((NG_COUNT + 1))
    echo "| ${st} | ${nm} | ${dt} |"
  done
  echo ""
  [ "$NG_COUNT" -eq 0 ] \
    && echo "**overall: GO** — 全チェック成功" \
    || echo "**overall: 要判断** — NG ${NG_COUNT} 件 (artifact と本表で切り分ける)"
} | tee -a "$SUMMARY"

# runner ジョブ自体は「スパイクが最後まで走った」ことを成功とする。go/no-go は SPIKE RESULT で判断する。
exit 0
