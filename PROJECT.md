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
8. **サードパーティ action は commit SHA で固定**: タグは可変で、action リポジトリが侵害されるとタグごと悪性コードへ差し替えられる。`uses:` はフルレングスの commit SHA + バージョンコメント（例: `actions/checkout@34e11487... # v4.3.1`）で固定する。GitHub 公式推奨の hardening（https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions ）。バージョン更新時は `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` で SHA を確認して書き換える
9. **runner スクリプトは workflow と同一 commit に固定**: reusable workflow（session.yml）は runner スクリプトを `job.workflow_repository` / `job.workflow_sha`（= 呼ばれた workflow ファイルの repo と commit SHA。`github.job_workflow_sha` というプロパティは存在しない）で checkout する。caller が `uses:` を SHA 固定していれば、実行されるスクリプトも同じ SHA に固定される

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

### 各アプリ repo での実行（reusable workflow）

GitHub の Additional Product Terms は、GitHub-hosted runner の用途を「workflow が動く repo に紐づくソフトウェアプロジェクト」の production / testing / deployment / publication に限定している（https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features ）。simtunnel の runner で他アプリをビルド・操作するのはこれに抵触するため、**実アプリで使う時は各アプリ repo で workflow を動かす**。

- `session.yml` を reusable workflow（`workflow_call`）とし、各アプリ repo からは薄い caller workflow で呼ぶ。simtunnel 自身は `simulator-session.yml`（`workflow_dispatch` ラッパー）経由で呼ぶ
- **simtunnel は public のまま維持する**。private 化すると (a) public repo から private repo の reusable workflow は呼べない（https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository ）、(b) runner スクリプトの checkout に PAT が必要になる、(c) simtunnel 自身の検証 run が月 200 macOS 分に制限される
- アプリ repo も public にする（macOS runner 無料のため）。public 化前に履歴へのシークレット混入が無いことを点検する
- OIDC token の subject は **caller repo 基準**になるため、アプリ repo 側に Secrets（`TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`）の登録が必要。trust credential は **subject ワイルドカード `repo:bannzai/*` が使える**（検証済み 2026-07-06。Tailscale docs の「Values can contain an `*`」のとおり動作）ため、1 credential + 同一 Secrets 値で全 repo をカバーできる。トレードオフ: オーナー配下の任意 repo の workflow が tag:ci の auth key を発行できるようになる（tag:ci は ACL で発信全拒否のため影響は限定的）。repo 単位に絞りたい場合は Subject `repo:<owner>/<repo>:*` で個別発行する（「Tailscale セットアップ手順」の subject 読み替え）
- Actions cache は repo 単位のため、アプリ repo ごとに初回 run は WDA ビルドが走る（2 回目以降はキャッシュヒット）
- ビルド対象は input（`build_project` / `build_scheme` / `build_configuration`）で渡す。`build_project` は caller repo ルート相対の .xcodeproj / .xcworkspace パス。bundle id はビルド成果物から自動取得する

caller workflow の例（アプリ repo の `.github/workflows/simulator-session.yml`）:

```yaml
name: simulator-session
# run-name は local/simtunnel CLI が run を特定するキーのためこの形式を維持する
run-name: "session=${{ inputs.session }} device=${{ inputs.device }}"

on:
  workflow_dispatch: # fork PR に Secrets を渡さないため workflow_dispatch のみ
    # session / device / duration_minutes は local/simtunnel の up が常に送るため宣言必須
    # （未定義の input を送ると dispatch が拒否される）
    inputs:
      session:
        required: true
        default: dev
      device:
        required: true
        default: iPhone 17
      duration_minutes:
        required: true
        default: "60"

permissions:
  id-token: write # Tailscale の OIDC 認証に必要
  contents: read

jobs:
  session:
    # タグ運用はしないため main の commit SHA で固定する（更新時は SHA を書き換える）
    uses: bannzai/simtunnel/.github/workflows/session.yml@<commit SHA> # main
    with:
      session: ${{ inputs.session }}
      device: ${{ inputs.device }}
      duration_minutes: ${{ inputs.duration_minutes }}
      build_project: MyApp.xcodeproj
      build_scheme: MyApp
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
```

ローカル CLI は `SIMTUNNEL_REPO` でアプリ repo に向ける（`SIMTUNNEL_WORKFLOW` は caller workflow のファイル名。既定 `simulator-session.yml`）:

```bash
SIMTUNNEL_REPO=<owner>/<repo> local/simtunnel up <session> --wait
```

#### ビルドに自由な step が必要なアプリ（Flutter 等）: build job 分割 + artifact 渡し

`build_project` input（xcodebuild 直叩き）で表現できないビルド（Flutter の SDK セットアップ、ビルド前の secret 復元等）は、caller 側の **build job** で自由にビルドして Simulator 用 .app を artifact にアップロードし、session job へ `app_artifact` input で渡す。

- secrets はネイティブに build job の step へ渡せる（reusable workflow に app 固有 secrets を通す必要がない）
- artifact の転送は GitHub 内部で完結するため DERP 帯域の制約を受けない
- 代償として runner 2 台が直列になり、起動待ちは「アプリのビルド時間 + セッション準備」になる
- `upload-artifact` の `path` は **.app の親ディレクトリ**（例: `build/ios/iphonesimulator`）を指定する。.app そのものを指定すると中身が flatten されて .app として復元できない

caller workflow の例（Flutter / bannzai/Pilll の場合の骨子）:

```yaml
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@<commit SHA> # v4.3.1
      - run: make secret # アプリ固有のビルド前準備（secrets は build job にネイティブに渡す）
        env:
          FILE_FIREBASE_IOS: ${{ secrets.FILE_FIREBASE_IOS_DEVELOPMENT }}
      - uses: subosito/flutter-action@<commit SHA> # v2.23.0
        with:
          flutter-version: '3.41.9'
      - run: flutter pub get
      - run: flutter build ios --simulator --debug --target lib/main.dev.dart
      - uses: actions/upload-artifact@<commit SHA> # v5.0.0
        with:
          name: simulator-app
          path: build/ios/iphonesimulator # .app の親ディレクトリ
  session:
    needs: build
    uses: bannzai/simtunnel/.github/workflows/session.yml@<commit SHA> # main
    with:
      session: ${{ inputs.session }}
      device: ${{ inputs.device }}
      duration_minutes: ${{ inputs.duration_minutes }}
      app_artifact: simulator-app
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
```

## Tailscale セットアップ手順（Phase 0 実施記録）

管理コンソールでの操作。**順序厳守（ACL が先。「リポジトリ公開に耐える安全性」の 5 を参照）**。

### 1. ACL の設定

https://login.tailscale.com/admin/acls

JSON editor に切り替え、ポリシーファイル全体を上記「リポジトリ公開に耐える安全性」の grants 構文の方針で編集して Save する。注意: コメントに非 ASCII 文字を使うと、貼り付け時に parse error になることがある（実際になった）。コメントは英語で書く。

### 2. Trust credential の発行（OIDC）

https://login.tailscale.com/admin/settings/trust-credentials

1. **New credential** → credential type で **OpenID Connect** を選択
2. Issuer: **GitHub** / Subject: `repo:bannzai/simtunnel:*`（複数 repo をカバーする場合はワイルドカード `repo:bannzai/*` も可。検証済み。トレードオフは「各アプリ repo での実行」参照）
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

## リポジトリ構成

```text
simtunnel/
├── PROJECT.md                        # 本ファイル（設計の SSOT）
├── CLAUDE.md
├── .github/workflows/
│   ├── session.yml                   # reusable workflow (workflow_call): Simulator セッションの実体
│   └── simulator-session.yml         # workflow_dispatch: simtunnel 自身用の薄いラッパー（session.yml を呼ぶ）
├── iOSProject/                       # サンプルアプリ（SwiftUI + SwiftData / deployment target iOS 26.x）
├── runner/                           # GHA 側スクリプト
│   ├── boot-simulator.sh             # simctl boot + 起動待ち（複数ランタイム時は最新 iOS を優先）
│   ├── install-app.sh                # app_zip_url の .app を install / launch（未指定ならスキップ）
│   ├── install-artifact-app.sh       # app_artifact（caller build job の成果物）の .app を install / launch
│   ├── build-app.sh                  # build_project / build_scheme を runner 上でビルドして install / launch
│   ├── start-wda.sh                  # WDA を build-for-testing（キャッシュ対応）+ test-without-building で起動
│   ├── start-serve-sim.sh            # serve-sim を起動（ブラウザ操作 UI + ライブ映像を :3200 で配信）
│   ├── bridge.sh                     # socat: tailscale IF → 指定ポート（直接到達可能ならスキップ）
│   └── keepalive.sh                  # duration_minutes までジョブを維持（WDA 死活監視付き）
├── local/
│   └── simtunnel                     # ローカル CLI: up / down / list / status / screenshot / preview / wait
└── mcp/                              # simtunnel-mcp（index.mjs。SIMTUNNEL_WDA_URL で接続先指定）
```

## MCP の登録

事前に `mcp/` ディレクトリで `npm install` を 1 回実行しておく。

### Claude Code（worktree ごとに別セッションを割り当てる）

worktree のプロジェクトルートに `.mcp.json` を置く:

```json
{
  "mcpServers": {
    "simtunnel": {
      "command": "node",
      "args": ["<simtunnel リポジトリの絶対パス>/mcp/index.mjs"],
      "env": { "SIMTUNNEL_WDA_URL": "http://simtunnel-<session>:8100" }
    }
  }
}
```

生成ヘルパーで書き込む場合（既存 `.mcp.json` の対象サーバ名以外のエントリは保持される）:

```bash
<simtunnel リポジトリの絶対パス>/local/simtunnel mcp-config <session> [worktree のパス] [--name mobile]
```

### mobile-mcp 互換ツール

simtunnel-mcp はネイティブツール（status / tap 等）に加えて、mobile-mcp と同名・同引数の互換ツール（`mobile_take_screenshot` / `mobile_click_on_screen_at_coordinates` 等）を提供する。`mcp-config <session> <worktree> --name mobile` でサーバ名を `mobile` にすると、ツールのフルネームが `mcp__mobile__mobile_*` になり、mobile-mcp 前提の既存 skill（verify-ui-mobile-mcp 等）がそのまま動く。

- `device` 引数は受け取るが無視する（1 サーバ = 1 セッション）。`mobile_list_available_devices` は接続先セッション 1 台を返す
- 座標はネイティブツールと同じポイント単位（mobile-mcp も iOS では WDA のポイント座標を使うため互換）
- `mobile_launch_app` / `mobile_terminate_app` は WDA の apps API で対応。`mobile_list_apps` / `mobile_install_app` / `mobile_uninstall_app` は simctl が必要なため未対応（呼ぶと代替手段を案内するエラーを返す。install は workflow の `sample_app` / `app_zip_url` input で行う）
- 本家 mobile-mcp を同じセッションに登録している場合はサーバ名 `mobile` が衝突するため、worktree では `--name mobile` はどちらか一方だけにする

コマンドで登録する場合:

```bash
claude mcp add simtunnel -e SIMTUNNEL_WDA_URL=http://simtunnel-<session>:8100 -- node <simtunnel リポジトリの絶対パス>/mcp/index.mjs
```

### Codex

`~/.codex/config.toml`:

```toml
[mcp_servers.simtunnel]
command = "node"
args = ["<simtunnel リポジトリの絶対パス>/mcp/index.mjs"]
env = { SIMTUNNEL_WDA_URL = "http://simtunnel-<session>:8100" }
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

### Phase 2: セッション管理・並列化（完了: 2026-07-05）
- [x] `local/simtunnel` CLI: `up` / `down` / `list` / `status` / `screenshot` / `wait`（up / down は冪等。down は run-name の `session=<name>` 一致で対象 run をキャンセル）
- [x] `simtunnel screenshot <session>`: MJPEG フレーム抽出による高速スクリーンショット（1 枚約 80〜100KB / 数秒。`GET /screenshot` の 68 秒から大幅短縮）
- [x] 複数セッション同時起動: dev-a / dev-b の 2 並列で検証。両方 ready まで約 4 分（Phase 1 の 10 分より速かった。WDA ビルド時間はばらつく）。tap を送ったセッションだけ画面が変わることをスクリーンショットで確認（独立性 OK）。終了後は両ノードとも tailnet から自動削除された
- [x] アプリの install / launch を workflow input（`app_zip_url` / `bundle_id`）で指定可能にする（`app_zip_url` 経路は実装のみ。実アプリ検証は下記「サンプルアプリ E2E」の repo 内ビルド方式で完了）
- 5 並列上限そのものの挙動確認は未実施（5 セッション必要になった時に確認する）

### サンプルアプリ E2E（完了: 2026-07-05）
- [x] リポジトリに iOSProject（SwiftUI + SwiftData のテンプレート / deployment target iOS 26.5）を追加
- [x] runner を macos-26（デフォルト Xcode 26.5 / iOS 26.x Simulator）へ移行。デフォルトデバイスは iPhone 17（macos-26 に iPhone 16 は無い）
- [x] `sample_app` input（デフォルト true）: チェックアウト済みソースから runner 上でビルド → install → launch。.app を DERP の細い帯域で転送せずに済む
- [x] E2E: 「+」を tap して SwiftData の Item 行が追加されることをスクリーンショットで確認
- 実測（WDA キャッシュミス回）: dispatch → 操作可能まで約 7.5 分。内訳: Simulator boot 138 秒 / アプリビルド 119 秒 / WDA ビルド + 起動 131 秒（macos-26 runner は WDA ビルドがかなり速い）
- ハマり: macos-26 は iOS 26.2 / 26.4 / 26.5 の複数ランタイムを持ち、古いランタイムの同名デバイスを掴むと新しい deployment target のアプリが destination エラーになる → boot-simulator.sh を最新ランタイム優先に変更した

### Phase 3: simtunnel-mcp（完了: 2026-07-05）
- [x] WDA API を直接叩く MCP サーバ実装（status / screen_info / screenshot / tap / swipe / type_text / press_button / source / open_url）
- [x] `SIMTUNNEL_WDA_URL` で接続先指定（MJPEG URL は :9100 を自動導出。`SIMTUNNEL_MJPEG_URL` で上書き可）。WDA セッションは失効時に自動再作成
- [x] MCP プロトコル経由の E2E 検証: initialize → tools/list → 全ツール実行。tap + type_text の結果が screenshot ツールの画像に反映されることを確認
- [x] Claude Code / Codex 両対応の登録手順を記載（「MCP の登録」参照）
- 座標系: screenshot はピクセル、tap / swipe はポイント。`screen_info` が返す scale（例: 3）で ピクセル ÷ scale = ポイント に変換する

### Phase 4: 拡張
- [x] WDA のビルド高速化（完了: 2026-07-05）: WDA を `WDA_REF`（v15.1.3）に固定し、`build-for-testing` の成果物（4.8MB）を actions/cache に保存。ヒット時は clone / ビルドをスキップして `test-without-building` で起動
  - 実測: dispatch → 操作可能まで、キャッシュミス約 4.8 分 / **ヒット約 2.8 分**（改善前は約 10 分）
  - ジョブは `down` で cancel されるため、post step ではなくビルド直後に明示保存する
- [x] serve-sim 統合（完了: 2026-07-05）: `serve_sim` input（デフォルト true）で EvanBacon/serve-sim を起動し、ブラウザからライブ映像閲覧 + 双方向操作（タップ / スワイプ / キー入力）ができる preview UI を :3200 で tailnet に公開
  - 検証: preview UI（HTTP 200）と `/helper/<UDID>/stream.mjpeg`（:3200 経由）からライブフレーム 40 枚取得を確認。操作 UI 自体はブラウザで対話的に使う（制御は `ws://.../helper/<UDID>/ws`）
  - serve-sim は無認証 + shell-exec route を持つため bind は 127.0.0.1 のまま、到達経路を tailnet 内に限定（WDA と同じ原則）。この設計判断は「リポジトリ公開に耐える安全性」の範囲内
  - `local/simtunnel preview <session>` でブラウザを開く（Host ヘッダから stream URL を組むため MagicDNS 名で開く）
  - **ストリームは実質 1 クライアント占有**（実測）。別のブラウザ（agent-browser 含む）が掴んでいると「No simulator / connecting」のまま繋がらない。繋がらない時はまず他のクライアントを閉じる。「control socket connect timeout」が出た場合は Retry で復旧する
- [x] mobile-mcp 互換ツール（完了: 2026-07-06）: `mcp__mobile__*` ツール名前提の既存 skill を simtunnel 経由で動かすための互換レイヤーを simtunnel-mcp に追加。詳細は「MCP の登録 > mobile-mcp 互換ツール」
- [ ] simtunnel-agentd: runner 上の HTTP 受け口（tailnet 内限定）で simctl を遠隔実行
      （ローカルでビルドした .app を zip で転送 → install → launch のループを可能にする。
      per-repo 展開によりアプリは各 repo の runner でビルドするため優先度は下がった）
- [ ] 1 runner 複数 Simulator（WDA を 8100+i / 9100+i で複数起動。Runner のメモリ制約を要検証）

### Phase 5: 各アプリ repo への展開
- [x] reusable workflow 化（完了: 2026-07-06）: `session.yml`（workflow_call）+ `simulator-session.yml`（dispatch ラッパー）に分割。ビルド対象を input 化（`build_project` / `build_scheme` / `build_configuration`）。runner スクリプトは `github.job_workflow_sha` で同一 commit を checkout。ローカル CLI は `SIMTUNNEL_REPO` / `SIMTUNNEL_WORKFLOW` で対象 repo を切り替え（詳細:「各アプリ repo での実行」）
- [x] Tailscale trust credential の subject ワイルドカード検証（完了: 2026-07-06）: Subject `repo:bannzai/*` の credential で SimTunnelDemoProject の run が認証成功。1 credential + 同一 Secrets 値で全 repo をカバーできる
- [x] SwiftUI 実験 repo（bannzai/SimTunnelDemoProject）で実戦（完了: 2026-07-06）: caller workflow + Secrets をセットアップし、up → status 200 → mcp-config → mobile-mcp 互換ツールで tap / screenshot / HOME / launch_app → down の一連を確認（記録: SimTunnelDemoProject PR #1 のコメント）。`local/simtunnel` は `up` だけでなく `down` / `status` 等も `SIMTUNNEL_REPO` 指定が必要
- [ ] Flutter (bannzai/Pilll) への展開。runner での Flutter ビルド方法（SDK セットアップ / build step の設計）は未決定

## 未検証事項・リスク

- ~~WDA の bind interface~~: **解決済み（Phase 1 実測）**。Simulator 上の WDA は 8100/9100 を全インターフェースで listen し、bridge は不要だった。挙動が変わった時の保険として bridge.sh は残す（到達可能なら何もしない）
- **転送帯域**: GHA runner ↔ ローカル間は direct 接続が確立せず DERP relay 経由（Phase 1 実測）。制御系 API（tap / 入力 / status）は 0.5〜2 秒で実用範囲だが、大きなレスポンスの転送は遅い。スクリーンショットは MJPEG フレーム抽出で回避。`.app` 転送（Phase 4）はこの帯域がボトルネックになる可能性が高い
- ~~WDA 起動時間~~: **解決済み（Phase 4）**。ビルドキャッシュ導入で dispatch → 操作可能は約 2.8 分（キャッシュヒット時）
- **`down` 直後の同名セッション再起動**: ephemeral node が tailnet から消えるまで数十秒かかり、その間の `up <同名>` は冪等チェックに当たって何もしない。`simtunnel list` でノード消滅を確認してから `up` する
- **同時実行上限**: Free プランは macOS 5 並列。worktree を跨いだ総セッション数の上限になる
- **repo を跨いだ同名セッション**: 同時起動防止の concurrency group は repo 単位のため、別 repo で同名セッションを起動すると tailnet ホスト名 `simtunnel-<session>` が衝突する。repo ごとに接頭辞を変える等、セッション名の一意性は運用で担保する
- **Runner スペック**: GitHub-hosted macOS (arm64) はメモリが小さめ。1 runner 複数 Simulator の成立性は要検証
- **MagicDNS の伝播ラグ**: ephemeral node の tailnet 参加後、`simtunnel-<session>` の名前解決ができるまで数分かかることがある（実測 2026-07-06。IP 直なら即到達可能）。`.mcp.json` のホスト名接続が ready 直後に ENOTFOUND になったら少し待って再試行する
- **keepalive 開始直後の WDA 無応答**: keepalive の死活チェックが開始 5 秒で失敗し run が failure 終了した事例を 1 回観測（2026-07-06。再現条件未特定。同日は runner が全体に遅く、サンプルアプリのビルドが通常 2 分 → 10 分超だった）。セッションが早期に消えたら run の failure step を確認し、再度 `up` する
