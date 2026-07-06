#!/usr/bin/env node
// SimTunnel MCP server。
// GHA 上の iOS Simulator を制御する WDA (WebDriverAgent) の HTTP API を薄くラップする。
// 接続先は env SIMTUNNEL_WDA_URL (例: http://simtunnel-dev:8100)。
// スクリーンショットは WDA の MJPEG サーバ (:9100) のフレーム抽出で取得する
// (GET /screenshot は DERP relay 経由だと 1 分超かかるため。PROJECT.md「Phase 1 実測」参照)。
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import http from "node:http";
import { writeFileSync } from "node:fs";

const WDA_URL = process.env.SIMTUNNEL_WDA_URL;
if (!WDA_URL) {
  console.error("env SIMTUNNEL_WDA_URL が必要 (例: http://simtunnel-dev:8100)");
  process.exit(1);
}
const MJPEG_URL =
  process.env.SIMTUNNEL_MJPEG_URL ??
  (() => {
    const url = new URL(WDA_URL);
    url.port = "9100";
    url.pathname = "/";
    return url.toString();
  })();

async function wda(method, path, body) {
  const res = await fetch(new URL(path, WDA_URL), {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = JSON.stringify(json.value ?? json).slice(0, 300);
    throw new Error(`WDA ${method} ${path} -> HTTP ${res.status}: ${detail}`);
  }
  return json.value;
}

let sessionId = null;

async function ensureSession() {
  if (sessionId) return sessionId;
  const value = await wda("POST", "/session", { capabilities: { alwaysMatch: {} } });
  sessionId = value.sessionId;
  return sessionId;
}

// WDA セッションが失効していたら作り直して 1 回だけリトライする
async function withSession(fn) {
  let sid = await ensureSession();
  try {
    return await fn(sid);
  } catch (e) {
    const msg = String(e);
    if (msg.includes("invalid session") || msg.includes("Session does not exist") || msg.includes("HTTP 404")) {
      sessionId = null;
      sid = await ensureSession();
      return await fn(sid);
    }
    throw e;
  }
}

// MJPEG ストリームから最後に完成したフレーム (= 最新の画面) を 1 枚取り出す
function grabFrame(timeoutMs = 20_000) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let done = false;

    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      req.destroy();
      const buf = Buffer.concat(chunks);
      const end = buf.lastIndexOf(Buffer.from([0xff, 0xd9]));
      const start = end > 0 ? buf.lastIndexOf(Buffer.from([0xff, 0xd8]), end) : -1;
      if (start < 0 || end < 0) {
        reject(new Error(`MJPEG フレームを取得できなかった (受信 ${buf.length} bytes)。セッションの準備状態を確認`));
        return;
      }
      resolve(buf.subarray(start, end + 2));
    };

    const timer = setTimeout(finish, timeoutMs);
    const req = http.get(MJPEG_URL, (res) => {
      res.on("data", (c) => {
        chunks.push(c);
        total += c.length;
        // 2 フレーム分程度を受信したら十分 (1 フレーム約 100KB)
        if (total > 300 * 1024) finish();
      });
      res.on("end", finish);
      res.on("error", finish);
    });
    req.on("error", (e) => {
      clearTimeout(timer);
      if (!done) {
        done = true;
        reject(e);
      }
    });
  });
}

function tapActions(x, y, pressMs = 100) {
  return {
    actions: [
      {
        type: "pointer",
        id: "finger1",
        parameters: { pointerType: "touch" },
        actions: [
          { type: "pointerMove", duration: 0, x, y },
          { type: "pointerDown", button: 0 },
          { type: "pause", duration: pressMs },
          { type: "pointerUp", button: 0 },
        ],
      },
    ],
  };
}

function swipeActions(fromX, fromY, toX, toY, durationMs = 500) {
  return {
    actions: [
      {
        type: "pointer",
        id: "finger1",
        parameters: { pointerType: "touch" },
        actions: [
          { type: "pointerMove", duration: 0, x: fromX, y: fromY },
          { type: "pointerDown", button: 0 },
          { type: "pointerMove", duration: durationMs, x: toX, y: toY },
          { type: "pointerUp", button: 0 },
        ],
      },
    ],
  };
}

const server = new McpServer({ name: "simtunnel", version: "0.2.0" });
const text = (s) => ({ content: [{ type: "text", text: s }] });

server.registerTool(
  "status",
  { description: "WDA の死活確認。接続先セッションが準備できているかを返す", inputSchema: {} },
  async () => text(JSON.stringify(await wda("GET", "/status"))),
);

server.registerTool(
  "screen_info",
  {
    description:
      "画面のスケール情報を返す。screenshot 画像はピクセル、tap/swipe の座標はポイント。ピクセル座標 ÷ scale = ポイント座標",
    inputSchema: {},
  },
  async () => {
    const screen = await withSession((sid) => wda("GET", `/session/${sid}/wda/screen`));
    const size = await withSession((sid) => wda("GET", `/session/${sid}/window/size`)).catch(() => null);
    return text(JSON.stringify({ scale: screen?.scale, pointSize: size, raw: screen }));
  },
);

server.registerTool(
  "screenshot",
  {
    description:
      "現在の画面を JPEG で取得する (MJPEG フレーム抽出)。画像はピクセル単位。tap 座標に使う時は screen_info の scale で割ってポイントに変換する",
    inputSchema: {},
  },
  async () => {
    const frame = await grabFrame();
    return {
      content: [{ type: "image", data: frame.toString("base64"), mimeType: "image/jpeg" }],
    };
  },
);

server.registerTool(
  "tap",
  {
    description: "座標をタップする (ポイント単位)",
    inputSchema: { x: z.number(), y: z.number() },
  },
  async ({ x, y }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/actions`, tapActions(x, y)));
    return text(`tapped (${x}, ${y})`);
  },
);

server.registerTool(
  "swipe",
  {
    description: "スワイプする (ポイント単位)",
    inputSchema: {
      from_x: z.number(),
      from_y: z.number(),
      to_x: z.number(),
      to_y: z.number(),
      duration_ms: z.number().default(500),
    },
  },
  async ({ from_x, from_y, to_x, to_y, duration_ms }) => {
    await withSession((sid) =>
      wda("POST", `/session/${sid}/actions`, swipeActions(from_x, from_y, to_x, to_y, duration_ms)),
    );
    return text(`swiped (${from_x}, ${from_y}) -> (${to_x}, ${to_y})`);
  },
);

server.registerTool(
  "type_text",
  {
    description: "フォーカス中の入力欄にテキストを入力する",
    inputSchema: { text: z.string() },
  },
  async ({ text: value }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/wda/keys`, { value: [value] }));
    return text(`typed: ${value}`);
  },
);

server.registerTool(
  "press_button",
  {
    description: "ハードウェアボタンを押す",
    inputSchema: { name: z.enum(["home", "volumeUp", "volumeDown"]) },
  },
  async ({ name }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/wda/pressButton`, { name }));
    return text(`pressed: ${name}`);
  },
);

server.registerTool(
  "source",
  {
    description:
      "画面のアクセシビリティツリーを取得する (JSON)。要素の座標や label の確認に使う。大きい画面では応答に時間がかかる",
    inputSchema: {},
  },
  async () => {
    const value = await wda("GET", "/source/?format=json");
    let s = JSON.stringify(value);
    const LIMIT = 100_000;
    if (s.length > LIMIT) {
      s = `${s.slice(0, LIMIT)}\n...(${s.length - LIMIT} 文字省略)`;
    }
    return text(s);
  },
);

server.registerTool(
  "open_url",
  {
    description: "URL を開く (Safari 等が起動する)",
    inputSchema: { url: z.string() },
  },
  async ({ url }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/url`, { url }));
    return text(`opened: ${url}`);
  },
);

// ---- mobile-mcp 互換ツール ----
// mcp__mobile__* のツール名を前提にした既存 skill を simtunnel 経由でも動かすための互換レイヤー。
// mobile-mcp と同名・同引数のツールを提供する（mcp-config --name mobile でサーバ名も合わせる）。
// device 引数は 1 サーバ = 1 セッションのため受け取って無視する。
// 座標はネイティブツールと同じくポイント単位（mobile-mcp も iOS では WDA のポイント座標をそのまま使う）。

const sessionHost = new URL(WDA_URL).hostname;
const deviceArg = z.string().optional().describe("互換用。無視される（このサーバは 1 セッション固定）");

async function pointScreenSize() {
  return withSession((sid) => wda("GET", `/session/${sid}/window/size`));
}

server.registerTool(
  "mobile_list_available_devices",
  { description: "利用可能なデバイス一覧（このサーバは接続先セッション 1 台のみを返す）", inputSchema: {} },
  async () => text(`Found 1 device: ${sessionHost} (iOS Simulator via simtunnel)`),
);

server.registerTool(
  "mobile_take_screenshot",
  { description: "現在の画面を JPEG で取得する（screenshot ツールと同じ。画像はピクセル、座標系はポイント）", inputSchema: { device: deviceArg } },
  async () => {
    const frame = await grabFrame();
    return { content: [{ type: "image", data: frame.toString("base64"), mimeType: "image/jpeg" }] };
  },
);

server.registerTool(
  "mobile_save_screenshot",
  {
    description: "現在の画面をファイルに保存する。MJPEG フレーム抽出のため保存形式は JPEG（.jpg / .jpeg のみ）",
    inputSchema: { device: deviceArg, saveTo: z.string().describe("保存先パス（.jpg / .jpeg）") },
  },
  async ({ saveTo }) => {
    if (!/\.jpe?g$/i.test(saveTo)) {
      throw new Error(`保存形式は JPEG のみ（.jpg / .jpeg）。PNG は未対応: ${saveTo}`);
    }
    const frame = await grabFrame();
    writeFileSync(saveTo, frame);
    return text(`saved: ${saveTo} (${frame.length} bytes)`);
  },
);

server.registerTool(
  "mobile_get_screen_size",
  { description: "画面サイズを返す（ポイント単位。tap 系の座標にそのまま使える）", inputSchema: { device: deviceArg } },
  async () => {
    const size = await pointScreenSize();
    const screen = await withSession((sid) => wda("GET", `/session/${sid}/wda/screen`)).catch(() => null);
    return text(JSON.stringify({ width: size.width, height: size.height, scale: screen?.scale ?? null }));
  },
);

// WDA の source ツリーから、表示中で label / name / value を持つ要素を平坦なリストにする
function collectElements(node, acc) {
  if (!node) return acc;
  const visible = node.isVisible === "1" || node.isVisible === 1 || node.isVisible === true;
  const label = node.label ?? "";
  const name = node.name ?? "";
  const value = node.value ?? "";
  if (visible && (label || name || value) && node.rect) {
    acc.push({
      type: String(node.type ?? "").replace(/^XCUIElementType/, ""),
      label,
      name,
      value,
      rect: node.rect,
    });
  }
  for (const child of node.children ?? []) collectElements(child, acc);
  return acc;
}

server.registerTool(
  "mobile_list_elements_on_screen",
  {
    description: "画面上の要素一覧を座標付きで返す。rect はポイント単位で tap 系の座標にそのまま使える",
    inputSchema: { device: deviceArg },
  },
  async () => {
    const tree = await wda("GET", "/source/?format=json");
    let s = JSON.stringify(collectElements(tree, []));
    const LIMIT = 100_000;
    if (s.length > LIMIT) {
      s = `${s.slice(0, LIMIT)}\n...(${s.length - LIMIT} 文字省略)`;
    }
    return text(s);
  },
);

server.registerTool(
  "mobile_click_on_screen_at_coordinates",
  { description: "座標をタップする（ポイント単位）", inputSchema: { device: deviceArg, x: z.number(), y: z.number() } },
  async ({ x, y }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/actions`, tapActions(x, y)));
    return text(`tapped (${x}, ${y})`);
  },
);

server.registerTool(
  "mobile_double_tap_on_screen",
  { description: "座標をダブルタップする（ポイント単位）", inputSchema: { device: deviceArg, x: z.number(), y: z.number() } },
  async ({ x, y }) => {
    await withSession((sid) =>
      wda("POST", `/session/${sid}/actions`, {
        actions: [
          {
            type: "pointer",
            id: "finger1",
            parameters: { pointerType: "touch" },
            actions: [
              { type: "pointerMove", duration: 0, x, y },
              { type: "pointerDown", button: 0 },
              { type: "pause", duration: 60 },
              { type: "pointerUp", button: 0 },
              { type: "pause", duration: 100 },
              { type: "pointerDown", button: 0 },
              { type: "pause", duration: 60 },
              { type: "pointerUp", button: 0 },
            ],
          },
        ],
      }),
    );
    return text(`double-tapped (${x}, ${y})`);
  },
);

server.registerTool(
  "mobile_long_press_on_screen_at_coordinates",
  {
    description: "座標を長押しする（ポイント単位）",
    inputSchema: { device: deviceArg, x: z.number(), y: z.number(), duration: z.number().min(1).max(10000).default(500) },
  },
  async ({ x, y, duration }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/actions`, tapActions(x, y, duration)));
    return text(`long-pressed (${x}, ${y}) for ${duration}ms`);
  },
);

server.registerTool(
  "mobile_swipe_on_screen",
  {
    description: "方向指定でスワイプする。開始点省略時は画面中央、distance 省略時は 400 ポイント（画面内に収まるよう調整）",
    inputSchema: {
      device: deviceArg,
      direction: z.enum(["up", "down", "left", "right"]),
      x: z.number().optional(),
      y: z.number().optional(),
      distance: z.number().default(400),
    },
  },
  async ({ direction, x, y, distance }) => {
    const size = await pointScreenSize();
    const startX = Math.round(x ?? size.width / 2);
    const startY = Math.round(y ?? size.height / 2);
    const [dx, dy] = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] }[direction];
    const clamp = (v, max) => Math.max(10, Math.min(max - 10, Math.round(v)));
    const endX = clamp(startX + dx * distance, size.width);
    const endY = clamp(startY + dy * distance, size.height);
    await withSession((sid) => wda("POST", `/session/${sid}/actions`, swipeActions(startX, startY, endX, endY)));
    return text(`swiped ${direction}: (${startX}, ${startY}) -> (${endX}, ${endY})`);
  },
);

server.registerTool(
  "mobile_type_keys",
  {
    description: "フォーカス中の入力欄にテキストを入力する。submit=true で末尾に Enter を送る",
    inputSchema: { device: deviceArg, text: z.string(), submit: z.boolean().default(false) },
  },
  async ({ text: value, submit }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/wda/keys`, { value: [submit ? `${value}\n` : value] }));
    return text(`typed: ${value}${submit ? " (+enter)" : ""}`);
  },
);

server.registerTool(
  "mobile_press_button",
  {
    description: "ボタンを押す。対応: HOME / VOLUME_UP / VOLUME_DOWN / ENTER（BACK / DPAD 系は Android 専用のため非対応）",
    inputSchema: { device: deviceArg, button: z.string() },
  },
  async ({ button }) => {
    const name = { HOME: "home", VOLUME_UP: "volumeUp", VOLUME_DOWN: "volumeDown" }[button];
    if (name) {
      await withSession((sid) => wda("POST", `/session/${sid}/wda/pressButton`, { name }));
    } else if (button === "ENTER") {
      await withSession((sid) => wda("POST", `/session/${sid}/wda/keys`, { value: ["\n"] }));
    } else {
      throw new Error(`非対応のボタン: ${button}（対応: HOME / VOLUME_UP / VOLUME_DOWN / ENTER）`);
    }
    return text(`pressed: ${button}`);
  },
);

server.registerTool(
  "mobile_open_url",
  { description: "URL を開く（Safari 等が起動する）", inputSchema: { device: deviceArg, url: z.string() } },
  async ({ url }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/url`, { url }));
    return text(`opened: ${url}`);
  },
);

server.registerTool(
  "mobile_launch_app",
  {
    description: "bundle id を指定してアプリを起動する（locale 引数は非対応で無視される）",
    inputSchema: { device: deviceArg, packageName: z.string().describe("iOS の bundle id"), locale: z.string().optional() },
  },
  async ({ packageName }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/wda/apps/launch`, { bundleId: packageName }));
    return text(`launched: ${packageName}`);
  },
);

server.registerTool(
  "mobile_terminate_app",
  {
    description: "bundle id を指定してアプリを終了する",
    inputSchema: { device: deviceArg, packageName: z.string().describe("iOS の bundle id") },
  },
  async ({ packageName }) => {
    await withSession((sid) => wda("POST", `/session/${sid}/wda/apps/terminate`, { bundleId: packageName }));
    return text(`terminated: ${packageName}`);
  },
);

server.registerTool(
  "mobile_get_orientation",
  { description: "画面の向きを返す（portrait / landscape）", inputSchema: { device: deviceArg } },
  async () => {
    const o = await withSession((sid) => wda("GET", `/session/${sid}/orientation`));
    return text(String(o).toLowerCase().startsWith("land") ? "landscape" : "portrait");
  },
);

server.registerTool(
  "mobile_set_orientation",
  {
    description: "画面の向きを変更する",
    inputSchema: { device: deviceArg, orientation: z.enum(["portrait", "landscape"]) },
  },
  async ({ orientation }) => {
    await withSession((sid) =>
      wda("POST", `/session/${sid}/orientation`, { orientation: orientation === "landscape" ? "LANDSCAPE" : "PORTRAIT" }),
    );
    return text(`orientation: ${orientation}`);
  },
);

// simctl が必要で WDA だけでは実現できない操作。呼ばれたら代替手段を案内するエラーを返す
const UNSUPPORTED = {
  mobile_list_apps: "インストール済みアプリ一覧は取得できない。起動するアプリの bundle id は既知の値を使う（サンプルアプリの launch は workflow が実施済み）",
  mobile_install_app: "install は workflow の sample_app / app_zip_url input で runner 側が行う（simtunnel up のオプション参照）",
  mobile_uninstall_app: "uninstall は未対応。セッションを down して新しいセッションを起動する",
};
for (const [name, guide] of Object.entries(UNSUPPORTED)) {
  server.registerTool(
    name,
    { description: `simtunnel では未対応（${guide}）`, inputSchema: { device: deviceArg } },
    async () => {
      throw new Error(`simtunnel では未対応: ${name}。${guide}`);
    },
  );
}

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`simtunnel-mcp: connected (WDA=${WDA_URL}, MJPEG=${MJPEG_URL})`);
