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

const server = new McpServer({ name: "simtunnel", version: "0.1.0" });
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
      wda("POST", `/session/${sid}/actions`, {
        actions: [
          {
            type: "pointer",
            id: "finger1",
            parameters: { pointerType: "touch" },
            actions: [
              { type: "pointerMove", duration: 0, x: from_x, y: from_y },
              { type: "pointerDown", button: 0 },
              { type: "pointerMove", duration: duration_ms, x: to_x, y: to_y },
              { type: "pointerUp", button: 0 },
            ],
          },
        ],
      }),
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

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`simtunnel-mcp: connected (WDA=${WDA_URL}, MJPEG=${MJPEG_URL})`);
