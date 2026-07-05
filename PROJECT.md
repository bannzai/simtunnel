# SimTunnel

GitHub Actions の macOS Runner 上で iOS Simulator + WebDriverAgent (WDA) を起動し、ローカルマシンの Claude / Codex から操作・スクリーンショット取得・画面ストリーミング閲覧を行うためのツール群。

## 目的

- ローカルの Mac のリソースを消費せずに、複数の iOS Simulator を並列に立ち上げて AI Agent に操作させる
- git worktree ごとに独立した Simulator セッションを割り当てる（1 worktree に複数セッションも可）
- 動作確認・スクリーンショット撮影・E2E 的な検証をローカルの Claude / Codex から実行する

## アーキテクチャ

```text
Local Mac
├─ worktree A の Claude Code ─→ http://simtunnel-a1:8100 (WDA)
├─ worktree B の Claude Code ─→ http://simtunnel-b1:8100
│                            └→ http://simtunnel-b2:8100  ※1 worktree に複数セッション可
└─ Tailscale クライアント（tailnet 内でのみ名前解決・到達可能）
        │
        │  暗号化 P2P / 公開インターネットにエンドポイントを一切公開しない
        │
GitHub Actions (workflow_dispatch)
├─ Job (session=a1): macOS Runner
│   ├─ iOS Simulator (iPhone 16 等)
│   ├─ WebDriverAgent      :8100（操作 API）
│   ├─ WDA MJPEG server    :9100（画面ストリーミング）
│   ├─ socat bridge（tailscale IF → 127.0.0.1:8100/9100）
│   └─ tailscale（ephemeral node / hostname=simtunnel-a1 / tag:ci）
├─ Job (session=b1): 同上
└─ Job (session=b2): 同上
```

- **1 ジョブ = 1 Runner = 1 Simulator = 1 tailnet ホスト名** を基本単位とする
- セッション名（例: `a1`, `focus-widget-1`）は `workflow_dispatch` の input で渡し、Tailscale の hostname `simtunnel-<session>` になる。ローカルからの接続先は毎回固定の名前で解決できる
- N 個の Simulator が欲しければ N ジョブ起動する。worktree とセッションの対応はローカル側の運用（CLI / .mcp.json）で管理し、GHA 側は関知しない

## 実現可能性の調査結果（2026-07-05 時点）

| 項目 | 結果 |
|---|---|
| GHA macOS Runner で Simulator 起動 | 可能。iOS テストで広く実績あり |
| ジョブ実行時間上限 | GitHub-hosted は最大 6 時間（`timeout-minutes` ≤ 360）。1 セッション = 1 ジョブは成立 |
| macOS Runner の料金 | public リポジトリは無料。private は消費分数 10 倍（Free プラン 2,000 分/月 → macOS 換算 200 分） |
| macOS Runner の同時実行数 | Free プランで最大 5。並列セッション数の上限になる |
| WDA の画面ストリーミング | WDA 内蔵の MJPEG サーバ（:9100）で可能 |
| mobile-mcp の遠隔利用 | **そのままでは不可**。WDA 接続先が `localhost:8100` ハードコードな上、install / launch / デバイス一覧は `xcrun simctl` のローカル直叩き。fork しても simctl 系のリモート化が別途必要 |
| Tailscale GitHub Action | OIDC（workload identity federation, GA）または OAuth client で ephemeral node として tailnet に参加。ジョブ終了で自動削除。hostname 指定可。OIDC は Tailscale 1.90.1 以降 |

参照:

https://docs.github.com/en/actions/reference/limits
https://github.com/tailscale/github-action
https://github.com/mobile-next/mobile-mcp
https://trinhngocthuyen.com/posts/tech/mobile-e2e-wda/

## 設計判断

### トンネル: Tailscale を採用

要件は「public リポジトリでも安全」。WDA は無認証の操作 API なので、到達できる = Simulator を完全に操作できる。よって「エンドポイントを公開しない」ことが唯一の安全な設計になる。

| 手段 | 評価 |
|---|---|
| **Tailscale（採用）** | 公開エンドポイントゼロ。runner が ephemeral node として自分の tailnet に参加し、自分のデバイスからだけ到達できる。ホスト名が毎回固定で URL 受け渡し不要。8100/9100 の複数ポートも追加コストなし |
| Cloudflare Tunnel (quick) | ランダムな **公開 URL** に無認証 WDA が晒される。public repo ではログから URL が漏れる経路もあり不採用 |
| ngrok | 同じく公開エンドポイント。無料枠は 1 トンネルで 8100/9100 の 2 本を通せない |
| reverse SSH | 認証はあるが中継用 VPS が別途必要。Tailscale で足りるため不採用 |

Tailscale は無料の Personal プラン（デバイス 100 台）で成立する。認証は OIDC（workload identity federation）で、長期シークレットを GitHub に保存しない。

### リポジトリ公開に耐える安全性

リポジトリは public で運用する。tailnet 内の実 IP 等の環境固有情報はこのリポジトリに書かない。

1. **公開エンドポイントゼロ**: WDA / MJPEG は tailnet 内からしか到達できない
2. **トリガーは `workflow_dispatch` のみ**: 起動できるのは write 権限者だけ。fork からの PR には Secrets / OIDC トークンの権限が渡らない
3. **長期シークレットを持たない（OIDC / workload identity federation）**: Tailscale への認証は、GitHub が workflow に発行する短命の OIDC トークンで行う。subject が `repo:bannzai/simtunnel:*` に一致する workflow しか認証できず、盗まれて困る静的シークレットがそもそも存在しない（Secrets の `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` は識別子であり秘密情報ではない）
4. **Tailscale ACL で双方向を絞る**: 自分のデバイス → `tag:ci` の 8100/9100 のみ許可。`tag:ci` からの発信は全拒否。tailnet 内のローカルデバイスは SSH 等のサービスを listen している可能性がある前提で設計する（Tailscale が与えるのはネットワーク到達性だけでログイン権限ではないが、listen 中のサービスは攻撃面になる）。万一 runner が汚染されても tailnet 内の他デバイスへ発信できないことをこのルールで保証する

```jsonc
// tailnet ポリシーの該当部分（grants 構文）
{
  "tagOwners": { "tag:ci": ["autogroup:admin"] },
  "grants": [
    // src を "*" から "autogroup:member" に絞る。tag 付きデバイスは member に
    // 含まれないため、tag:ci (runner) を src とする通信は全拒否になる
    { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] }
  ],
  // Save のたびに「tag:ci からローカルマシンの SSH に届かないこと」を自動検証する
  // (<local-tailscale-ip> は自分のマシンの 100.x アドレスに置き換える)
  "tests": [
    { "src": "tag:ci", "deny": ["<local-tailscale-ip>:22"] }
  ]
}
```

5. **ACL 設定 → runner 参加の順序は入れ替え不可**: Tailscale のデフォルトポリシーは全許可のため、ACL 未設定のまま `tag:ci` の runner を参加させると、runner から tailnet 内の全デバイスへ到達できる時間帯が生まれる。trust credential（OIDC）の発行・workflow の初回実行は必ず ACL 設定後に行う
6. **ephemeral node**: ジョブ終了と同時に tailnet から自動削除される。また workflow は WDA がローカルで応答してから tailnet に参加する（tailnet 内にいる時間を最小化）
7. **`timeout-minutes` でセッション上限**: 消し忘れても最大 6 時間で必ず落ちる

### 操作レイヤー: 段階的に構築（mobile-mcp の fork はしない）

mobile-mcp は調査の結果、WDA 接続先ハードコード + simctl ローカル直叩きの構造で、fork の改修範囲が広く upstream 追従コストも掛かる。代わりに:

- **Phase 1**: MCP なし。Claude / Codex が Bash + curl で WDA HTTP API を直接叩く（疎通検証はこれで完結する）
- **Phase 3**: WDA API を直接喋る薄い自作 MCP サーバ **simtunnel-mcp** を作る。接続先は env `SIMTUNNEL_WDA_URL` で指定し、worktree ごとの `.mcp.json` に別々のセッション URL を書けばマルチセッションと自然に噛み合う

WDA API は WebDriver 準拠 + 拡張で、必要な操作は全て HTTP で足りる（mobile-mcp のソースから確認済みの一覧）:

| 操作 | エンドポイント |
|---|---|
| 死活確認 | `GET /status` |
| セッション作成 / 削除 | `POST /session` / `DELETE /session/:id` |
| スクリーンショット | `GET /screenshot`（base64, セッション不要） |
| 画面サイズ | `GET /session/:id/wda/screen` |
| tap / swipe / long-press | `POST /session/:id/actions`（W3C pointer actions） |
| テキスト入力 | `POST /session/:id/wda/keys` `{ "value": ["..."] }` |
| HOME 等のボタン | `POST /session/:id/wda/pressButton` `{ "name": "home" }` |
| アクセシビリティツリー | `GET /source/?format=json` |
| URL を開く | `POST /session/:id/url` |
| 画面ストリーミング | `:9100`（MJPEG。ブラウザ / ffplay で閲覧） |

simctl が必要な操作（アプリの install / launch / terminate 等）は、Phase 1〜3 では workflow の step として GHA 側で実行し、Phase 4 で runner 上の小さな HTTP 受け口（simtunnel-agentd）に置き換える。

## Tailscale セットアップ手順（Phase 0 実施記録）

管理コンソールでの操作。**順序厳守（ACL が先。「リポジトリ公開に耐える安全性」の 5 を参照）**。

### 1. ACL の設定

https://login.tailscale.com/admin/acls

JSON editor に切り替え、ポリシーファイル全体を上記「リポジトリ公開に耐える安全性」の grants 構文の方針で編集して Save する。注意: コメントに非 ASCII 文字を使うと、貼り付け時に parse error になることがある（実際になった）。コメントは英語で書く。

### 2. Trust credential の発行（OIDC）

https://login.tailscale.com/admin/settings/trust-credentials

1. **New credential** → credential type で **OpenID Connect** を選択
2. Issuer: **GitHub** / Subject: `repo:bannzai/simtunnel:*`
3. Scopes: **Custom scopes** のまま一覧を下にスクロールし、**Keys > Auth Keys** の **Write** にチェック → タグは **tag:ci** を選択
4. 発行された **Client ID** と **Audience** を控える（OAuth client と違い secret は存在しない）

### 3. GitHub Secrets への登録

```bash
gh secret set TS_OIDC_CLIENT_ID -R bannzai/simtunnel
gh secret set TS_OIDC_AUDIENCE -R bannzai/simtunnel
```

workflow 側は `permissions: id-token: write` を付け、`tailscale/github-action@v4` に `oauth-client-id`（= Client ID）/ `audience` / `tags: tag:ci` / `hostname` を渡す。

参照:

https://tailscale.com/docs/features/workload-identity-federation
https://tailscale.com/kb/1623/trust-credentials

## リポジトリ構成（予定）

```text
simtunnel/
├── PROJECT.md                        # 本ファイル（設計の SSOT）
├── CLAUDE.md
├── .github/workflows/
│   └── simulator-session.yml         # workflow_dispatch: session 名を受けて Simulator セッションを張る
├── runner/                           # GHA 側スクリプト
│   ├── boot-simulator.sh             # simctl boot + 起動待ち
│   ├── start-wda.sh                  # WDA を xcodebuild test で起動し :8100 応答まで待つ
│   ├── bridge.sh                     # socat: tailscale IF → 127.0.0.1:8100/9100
│   └── keepalive.sh                  # 停止指示 or timeout までジョブを維持
├── local/
│   └── simtunnel                     # ローカル CLI: up / down / list / status / screenshot / tap
└── mcp/                              # Phase 3: simtunnel-mcp（SIMTUNNEL_WDA_URL で接続先指定）
```

## セッションのライフサイクル

```text
1. simtunnel up <session>
     └─ gh workflow run simulator-session.yml -f session=<session>
2. Runner: tailscale join (hostname=simtunnel-<session>)
     → Simulator boot → (アプリ install/launch) → WDA 起動 → socat bridge
3. Local: http://simtunnel-<session>:8100/status が 200 になったら ready
4. Claude / Codex が curl（Phase 3 以降は simtunnel-mcp）で操作
5. simtunnel down <session>
     └─ gh run cancel（ephemeral node は自動削除。timeout-minutes が保険）
```

## 実装フェーズ

### Phase 0: 準備（完了: 2026-07-05）
- [x] リポジトリを public で GitHub に作成
- [x] Tailscale: tailnet に `tag:ci` を定義し、ACL（grants 構文）を設定する
- [x] Tailscale: trust credential（OIDC / Issuer: GitHub / Subject: `repo:bannzai/simtunnel:*` / Auth Keys Write / `tag:ci`）を発行する
- [x] GitHub Secrets に `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` を登録

### Phase 1: 疎通（完了: 2026-07-05）
- [x] workflow: Simulator boot → WDA 起動 → tailscale join → socat bridge → keepalive
- [x] ローカルから `curl http://simtunnel-<session>:8100/status` が通る（MagicDNS 名 / IP どちらでも）
- [x] `GET /screenshot` で画像取得、W3C actions で tap、`/wda/keys` で入力（Spotlight 検索への入力を画面で確認）
- [x] `:9100` の MJPEG からフレーム取得（ストリーム動作確認）
- [x] WDA の起動所要時間・操作レイテンシを計測して本ファイルに記録（下記）

#### Phase 1 実測（2026-07-05 / macos-15 runner / iPhone 16 / iOS 18.5）

| 項目 | 実測値 |
|---|---|
| dispatch → WDA ローカル応答 | 約 7.5 分（WDA の xcodebuild ビルド込み） |
| dispatch → tailnet 経由で操作可能 | 約 10 分 |
| 経路 | direct 接続は確立せず DERP relay 経由。RTT 130〜200ms |
| `GET /status` | 約 0.5 秒 |
| tap（W3C actions） | 約 2.2 秒 |
| 文字入力（`/wda/keys`） | 約 1.2 秒 |
| `GET /screenshot`（PNG 4.1MB） | 68 秒（約 60KB/s）← ボトルネック |
| MJPEG 1 フレーム（JPEG 約 110KB） | 数秒 |

わかったこと:
- WDA は Simulator でも 8100/9100 を全インターフェースで listen し、socat bridge は不要だった（bind 挙動が変わった時の保険として bridge.sh は残す）
- DERP relay 経由の帯域が細く、PNG の `/screenshot` は実用に耐えない。スクリーンショットは MJPEG（:9100）のフレーム抽出（PNG 比 約 1/35 のサイズ）を既定にする

### Phase 2: セッション管理・並列化
- [ ] `local/simtunnel` CLI: `up <session>` / `down <session>` / `list` / `status <session>`
- [ ] `simtunnel screenshot <session>`: MJPEG フレーム抽出による高速スクリーンショット（Phase 1 実測より `GET /screenshot` は使わない）
- [ ] 複数セッション同時起動（同時実行上限 5 の挙動確認）
- [ ] サンプルアプリの install / launch を workflow input で指定可能にする

### Phase 3: simtunnel-mcp
- [ ] WDA API を直接叩く MCP サーバ実装（screenshot / tap / swipe / type / press_button / source / open_url）
- [ ] `SIMTUNNEL_WDA_URL` で接続先指定。worktree ごとに `.mcp.json` で別セッションを登録
- [ ] Claude Code / Codex 両対応（Codex は `~/.codex/config.toml` の MCP 設定）

### Phase 4: 拡張
- [ ] simtunnel-agentd: runner 上の HTTP 受け口（tailnet 内限定）で simctl を遠隔実行
      （ローカルでビルドした .app を zip で転送 → install → launch のループを可能にする）
- [ ] 1 runner 複数 Simulator（WDA を 8100+i / 9100+i で複数起動。Runner のメモリ制約を要検証）
- [ ] WDA のビルド高速化（prebuilt WDA の利用 or キャッシュ。要検証）

## 未検証事項・リスク

- ~~WDA の bind interface~~: **解決済み（Phase 1 実測）**。Simulator 上の WDA は 8100/9100 を全インターフェースで listen し、bridge は不要だった。挙動が変わった時の保険として bridge.sh は残す（到達可能なら何もしない）
- **転送帯域**: GHA runner ↔ ローカル間は direct 接続が確立せず DERP relay 経由（Phase 1 実測）。制御系 API（tap / 入力 / status）は 0.5〜2 秒で実用範囲だが、大きなレスポンスの転送は遅い。スクリーンショットは MJPEG フレーム抽出で回避。`.app` 転送（Phase 4）はこの帯域がボトルネックになる可能性が高い
- **WDA 起動時間**: 実測 7.5 分（ビルド込み）。prebuilt / キャッシュでの短縮は Phase 4
- **同時実行上限**: Free プランは macOS 5 並列。worktree を跨いだ総セッション数の上限になる
- **Runner スペック**: GitHub-hosted macOS (arm64) はメモリが小さめ。1 runner 複数 Simulator の成立性は要検証
