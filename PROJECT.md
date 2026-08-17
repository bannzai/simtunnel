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
│   ├─ simtunnel-agentd    :8200（許可した simctl 動詞のみ）
│   ├─ socat bridge（tailscale IF → 127.0.0.1:8100/9100/8200）
│   └─ tailscale（ephemeral node / hostname=simtunnel-a1 / tag:ci）
├─ Job (session=b1): 同上
└─ Job (session=b2): 同上
```

- **1 ジョブ = 1 Runner = 1 tailnet ホスト名** を基本単位とする（既定は Simulator 1 台）
- セッション名（例: `a1`, `focus-widget-1`）は `workflow_dispatch` の input で渡し、Tailscale の hostname `simtunnel-<session>` になる。ローカルからの接続先は毎回固定の名前で解決できる
- N 個の Simulator が欲しければ N ジョブ起動する。worktree とセッションの対応はローカル側の運用（CLI / .mcp.json）で管理し、GHA 側は関知しない
- `simulators` input で **1 runner に複数 Simulator** も載せられる。i 台目（0 始まり・2 台目以降はデバイスの clone）の WDA が `:8100+i` / MJPEG が `:9100+i` になり、CLI / mcp-config は `--slot <i>` で台を指定する。serve-sim は 1 プロセスで全台を :3200 から配信し、`preview --slot <i>` で台を切り替える。並列上限 5 runner を超えて Simulator を増やしたい時の手段だが、runner のメモリが小さいため 2〜3 台まで（「未検証事項・リスク」参照）

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

リポジトリは public で運用する。tailnet 内の実 IP 等の環境固有情報は、このリポジトリにも **run のログ・ステップサマリにも**書かない（後者は public リポジトリでは誰でも読める）。接続先は MagicDNS 名（`simtunnel-<session>`）で足りるため、runner 側が IP を出力する必要はない（`session.yml` のセッション情報出力と `bridge.sh` の両方が対象）。

1. **公開エンドポイントゼロ**: WDA / MJPEG は tailnet 内からしか到達できない
2. **トリガーは `workflow_dispatch` のみ**: 起動できるのは write 権限者だけ。fork からの PR には Secrets / OIDC トークンの権限が渡らない
3. **長期シークレットを持たない（OIDC / workload identity federation）**: Tailscale への認証は、GitHub が workflow に発行する短命の OIDC トークンで行う。subject がこのリポジトリを指す trust credential の Subject（形式は「Tailscale セットアップ手順」参照）に一致する workflow しか認証できず、盗まれて困る静的シークレットがそもそも存在しない（Secrets の `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` は識別子であり秘密情報ではない）
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

#### 機能追加でこの前提を崩さないための判断基準

公開エンドポイントゼロ・`workflow_dispatch` のみ・長期シークレットなし・`tag:ci` からの発信全拒否は、後から機能を足す時に崩れやすい。次の 3 つは**やらないこと**として固定する。

- **WDA / agentd / serve-sim に認証を足して公開エンドポイントにする方向は採らない**。トークンを付けても、漏れた時点でシミュレータの完全な乗っ取りになる（無認証の操作 API が背後にいるため）。「到達できないこと」が唯一の安全根拠であり、認証はその代替にならない
- **クライアントから受けた本文（シェルコマンド・スクリプト・Maestro flow YAML 等）を runner で実行する設計は採らない**。runner が実行してよいのは、リポジトリにコミット済みで ref（commit SHA）に固定された内容だけ。可変長の本文を受ける経路を 1 本でも開けると、動詞の許可リストは意味を失う
- **新しい操作能力を足す時は「主体が増えるのか、能力が増えるだけか」を整理して設計判断に書く**。到達できる相手が増えない（= 既に WDA でシミュレータを完全操作できる tailnet 内の自分のデバイスだけ）なら能力の追加であり、この前提の範囲内。新しい主体が到達できるようになるなら、それは機能追加ではなく前提そのものの変更として扱う

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

simctl が必要な操作（アプリの launch / terminate、通知の合成等）は、Phase 1〜3 では workflow の step として GHA 側で実行していた。Phase 4 で runner 上の小さな HTTP 受け口（simtunnel-agentd）を足し、セッション開始後にも呼べるようにした（下記「simtunnel-agentd」）。

### 画面の録画: `simtunnel record`

`:9100` の MJPEG は連続ストリームなのに、`simtunnel screenshot` は 1 フレーム抽出しかしない。数秒で消える通知バナーの発火は、撮った瞬間に出ていなければ判別できない（実例: bannzai/mementomorning の初回 QA で、通知バナーの発火確認が「1 フレーム抽出では判別不能」となり判定不能になった）。ストリームをローカルに録り続ける経路を `local/simtunnel record` として足す。

- **クライアント側で録る**（runner 側の `simctl io recordVideo` ではなく）。すでに tailnet に出ている MJPEG をそのまま保存するだけで済み、runner 側に新しい能力を足さずに解決する。録画ファイルは最初からローカルにあるため、DERP relay 越しに動画を取り出す必要もない
- **録画中は再エンコードしない**。multipart のヘッダだけ落として JPEG フレームをそのまま追記保存する（`.mjpeg` = JPEG の連結）。ローカルの負荷はディスク書き込みが支配的で軽微。mp4 が要る場合だけ、録画終了後に `--mp4`（ffmpeg）で変換する
- **MJPEG は実質 1 クライアント占有**（Phase 4 の serve-sim 実測と同じ制約）。録画中は `screenshot` / `preview` を併用できない
- 録画からフレームを切り出す: `ffmpeg -f mjpeg -i <出力.mjpeg> -fps_mode passthrough ./tmp/frame-%04d.jpg`
- **ストリームは実時間から数秒遅れて届く**（実測 2026-08-17: HOME を押してから録画に現れるまで約 9 秒。DERP relay のバッファリングによる）。確認したい操作の前に録画を始め、操作から十分あとまで録り続ける
- 用途: 通知バナー発火の事後確認、E2E 操作の証跡、flaky の再現調査

### simtunnel-agentd（許可リスト式の simctl 受け口）

WDA では届かない領域（起動引数を要する状態の作り込み、通知の合成、権限の許可・拒否、ステータスバーの整形）を遠隔から作れるようにするため、runner 上に `:8200` の HTTP 受け口を置く。**任意コマンドの実行は実装しない。動詞を固定した許可リスト式**にする。

| 動詞 | 対応する simctl | 用途 |
| --- | --- | --- |
| `POST /v1/relaunch` | `terminate` + `launch`（起動引数付き） | アプリ起動前に効かせる設定を要する状態の作り込み |
| `POST /v1/push` | `push`（payload は JSON スキーマ検証） | 通知の合成・通知タップ検証 |
| `POST /v1/record/start` / `/v1/record/stop` | `io recordVideo` | 必要区間だけの runner 側録画 |
| `POST /v1/privacy` | `privacy grant/revoke/reset`（service は列挙型） | 権限拒否・許可状態の作り込み |
| `POST /v1/status_bar` | `status_bar override/clear` | スクリーンショットの整形 |

**主体は増えず、能力だけが増える**: `:8200` に到達できるのは、既に `:8100` の無認証 WDA でシミュレータを完全操作できる tailnet 内の自分のデバイスだけ。新しく到達できる相手は生まれないため、「機能追加でこの前提を崩さないための判断基準」の範囲内に収まる。

安全側の設計（実装は `runner/agentd.py`、検証は `runner/test/test-agentd.py`）:

- クライアントから**コマンド文字列・ファイルパス・スクリプト本文を一切受けない**。受けるのは動詞 + スキーマ検証済みの引数だけで、未知のキーが 1 つでもあれば 400 で拒否する
- **UDID はサーバ側が解決する**。クライアントは `slot`（0 始まりの Simulator 番号）だけを送り、body に `udid` があれば拒否する
- **bundleId はこのセッションで install したアプリだけ許可する**。許可リストは別ファイルで持たず、`simctl listapps` の `ApplicationType = User` から毎回引く（runner の Simulator は毎回まっさらなため、ユーザーアプリ = このセッションで install したアプリになる）
- `relaunch` の起動引数は文字種 `[A-Za-z0-9_=-]`・16 個まで・1 個 64 文字までに制限する
- `push` の payload は `aps` オブジェクト必須・入れ子 6 段まで・JSON の基本型のみ。宛先の決定をサーバ側に一本化するため、`Simulator Target Bundle` を含む payload は拒否する
- `simctl spawn` / `openurl` / `keychain` / `addmedia` など、**シミュレータ内での任意実行やホストのファイル参照につながる動詞は追加しない**
- 呼び出しの監査ログは runner ローカル（`$RUNNER_TEMP/agentd-audit.log`）にだけ記録する。HTTP サーバの既定のアクセスログも stderr ではなくこのファイルへ流し、public repo の run ログ・ステップサマリに値を出さない
- **録画ファイルを転送するエンドポイントは持たない**。`record/stop` は runner 上のパスとサイズを返すだけにする。DERP relay 経由（実測 約 60KB/s）では動画の取り出しが現実的な時間で終わらず、ローカル側の録画は `simtunnel record` で足りるため
- **runner 側の録画は 1 slot につき 1 本・最長 10 分**。`record/start` は同じ slot の実行中の録画を止めてから始め、止め忘れた録画もサーバ側の watchdog が打ち切る。応答が届かず `recordingId` を受け取れなかったクライアントは録画を止められず、放っておくとジョブが終わるまで書き続けて runner のディスクを圧迫するため

ハマりどころ:

- **WDA / maestro のドライバ（`*.xctrunner`）も User アプリとして `listapps` に並ぶ**（実測 2026-08-17）。これを操作できると `relaunch` でセッション自体を殺せてしまうため、許可リストから除外している
- **`push` が 200 を返しても、対象アプリが通知許可を得ていなければバナーは表示されない**（実測 2026-08-17。simtunnel のサンプルアプリは通知許可を要求しないため、`push` は成功するが画面には出ない）。バナーの発火を確認したいアプリ側では、通知許可を得た状態を作ってから `push` する
- **`simctl io recordVideo` を SIGKILL すると、その runner のホスト録画が `Resource busy`（`Host recording is already in progress`）のまま残り、以降の `record/start` が全て失敗する**（実測 2026-08-17）。停止は SIGINT を間を置いて 2 回送り、SIGTERM を挟んでから SIGKILL する。この状態になったセッションでは runner 側の録画を諦め、ローカル側の `simtunnel record` を使う
- **`record/start` の直後の `record/stop` は SIGINT を取りこぼす**（実測 2026-08-17）。runner 側の録画は、確認したい操作を挟んでから止める

呼び出しはセッション名で直接 curl する（専用の CLI サブコマンドは持たない）:

```bash
curl -s http://simtunnel-<session>:8200/status
curl -s -X POST http://simtunnel-<session>:8200/v1/relaunch \
  -H 'Content-Type: application/json' -d '{"slot": 0, "args": ["-UITEST", "1"]}'
curl -s -X POST http://simtunnel-<session>:8200/v1/push \
  -H 'Content-Type: application/json' -d '{"payload": {"aps": {"alert": "夜のふりかえりの時間です"}}}'
curl -s -X POST http://simtunnel-<session>:8200/v1/privacy \
  -H 'Content-Type: application/json' -d '{"action": "revoke", "service": "photos"}'
curl -s -X POST http://simtunnel-<session>:8200/v1/status_bar \
  -H 'Content-Type: application/json' -d '{"time": "09:41", "batteryLevel": 100}'
```

Tailscale ACL で宛先ポートを列挙している場合は、`8200` を許可対象に追加する（許可していないと tailnet 内からも到達できない）。

### macOS アプリ対応（issue #23）

macOS アプリを複数 worktree / 複数 AI Agent で並列開発すると、ローカルの 1 GUI セッションを全員が共有して E2E 検証が衝突する（最前面ウィンドウ・入力フォーカス・URL scheme 配送先・ホスト状態の取り合い）。simtunnel の「1 job = 1 runner = 1 セッション」を macOS へ広げると、1 セッション = 1 台の独立デスクトップになり、この共有資源の衝突が構造的に解消される。

**現況**: go/no-go スパイクで実現可能性を検証済み（結果: **GO**）。本実装（session workflow の macOS 版）は未着手。

**スパイク**: `.github/workflows/macos-app-spike.yml`（workflow_dispatch）+ `runner/macos-app-spike.sh`。secret を使わず tailnet にも参加せず、macos-26 runner 内で WebDriverAgentMac を単体起動して検証する。runner image / Xcode 更新時の回帰確認として手動 dispatch で再実行できる。結果は job summary の SPIKE RESULT と artifact `macos-app-spike`（スクリーンショット等）で判断する。

**スパイク実測（GO / macos-26 / Xcode 26.5 / appium-mac2-driver v4.1.1 同梱の WebDriverAgentMac）**:

- **単体起動できる**: Appium 本体なしで `xcodebuild build-for-testing test-without-building -project WebDriverAgentMac.xcodeproj -scheme WebDriverAgentRunner -destination 'platform=macOS'`（環境変数 `USE_PORT` / `USE_HOST`）で起動し `/status` が応答。署名は ad-hoc の "Sign to Run Locally" で成立し dev 証明書は不要。デフォルト port は 10100
- **画面が撮れる**: `GET /screenshot`（`XCUIScreen.screenshot` 経路）で実画面のフル内容を取得できる（Calculator・Dock・メニューバーが写ることをスクショで確認）。`screencapture` CLI は macos-26 で ScreenCaptureKit の同意モーダルが絡み実内容が保証されないため、スクショは iOS の MJPEG と同様に WDA 側へ寄せる
- **アプリを操作できる**: `POST /session`（`appium:bundleId` で対象アプリを launch）→ キー入力（`/wda/keys`）で Calculator に `7*8=` を入力し結果 56 がアクセシビリティツリーに反映されることを確認。座標クリック（`/wda/click`）と W3C actions（`POST /session/:id/actions`）はいずれも 200
- **TCC**: `kTCCServiceAccessibility` は macos-26 runner で `com.apple.dt.Xcode-Helper` に既に付与済みで、XCTest 経由の操作・アクセシビリティツリー取得・スクショに追加付与は不要だった

**実装上の注意（mac2 の癖。本実装で踏む）**:

- `/source` は `format=xml` / `description` のみ対応（`json` は非対応）
- W3C actions の `pointerMove` は `duration` を秒に変換して `> 0.001s` を要求するため、ミリ秒指定の `1` は境界で弾かれる（2ms 以上にする）
- macOS のデスクトップは 1 runner に 1 つのため、iOS の `simulators` input（1 runner に複数台）に相当する並列は作れない。並列は runner 数で確保する
- 日本語 IME を通した入力検証は入力ソース有効化と IME 経由のキー合成が要り難易度が高いため、初期スコープ外

**本実装（step 2）の方針（案）**: iOS の `session.yml`（reusable workflow）+ 各アプリ repo の薄い caller という既存構成を macOS へそのまま展開する。流用するのは Tailscale OIDC / ACL / socat bridge / `local/simtunnel` のセッション管理 / `duration_minutes` の自動終了。差し替えるのは (a) Simulator boot → 対象 macOS アプリの build / launch、(b) iOS WDA → WebDriverAgentMac（port 10100）、(c) ライブ映像（serve-sim 相当）は WDA の screenshot ポーリング等で要検討。`open -g` による URL scheme 発火・`screencapture`・tmux 操作はシェルで runner 上直接実行する。

### 各アプリ repo での実行（reusable workflow）

GitHub の Additional Product Terms は、GitHub-hosted runner の用途を「workflow が動く repo に紐づくソフトウェアプロジェクト」の production / testing / deployment / publication に限定している（https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features ）。simtunnel の runner で他アプリをビルド・操作するのはこれに抵触するため、**実アプリで使う時は各アプリ repo で workflow を動かす**。

- `session.yml` を reusable workflow（`workflow_call`）とし、各アプリ repo からは薄い caller workflow で呼ぶ。simtunnel 自身は `simulator-session.yml`（`workflow_dispatch` ラッパー）経由で呼ぶ
- **simtunnel は public のまま維持する**。private 化すると (a) public repo から private repo の reusable workflow は呼べない（https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository ）、(b) runner スクリプトの checkout に PAT が必要になる、(c) simtunnel 自身の検証 run が月 200 macOS 分に制限される
- アプリ repo も public にする（macOS runner 無料のため）。public 化前に履歴へのシークレット混入が無いことを点検する
- OIDC token の subject は **caller repo 基準**になるため、アプリ repo 側に Secrets（`TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`）の登録が必要。trust credential は **subject ワイルドカード（`repo:<owner>@<owner_id>/*` 形式）が使える**（旧形式 `repo:<owner>/*` で 2026-07-06、現行形式で 2026-08-13 に検証済み。Tailscale docs の「Values can contain an `*`」のとおり動作）ため、1 credential + 同一 Secrets 値で複数 repo をカバーできる。トレードオフ: オーナー配下の任意 repo の workflow が tag:ci の auth key を発行できるようになる（tag:ci は ACL で発信全拒否のため影響は限定的）。repo 単位に絞りたい場合は Subject `repo:<owner>@<owner_id>/<repo>@<repo_id>:*` で個別発行する（subject の形式は「Tailscale セットアップ手順」参照）
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

jobs:
  session:
    # id-token: write が必要なのは reusable workflow を呼ぶこの job だけのため、job 単位で最小権限にする
    permissions:
      id-token: write # Tailscale の OIDC 認証に必要
      contents: read
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

ローカル CLI の対象 repo は「`SIMTUNNEL_REPO` → カレントディレクトリの repo（`gh repo view`）」の順で決まる。アプリ repo の作業ディレクトリ（worktree 含む）で実行するなら指定は要らない（`SIMTUNNEL_WORKFLOW` は caller workflow のファイル名。既定 `simulator-session.yml`）:

```bash
# 対象 repo は gh から解決（アプリ repo 側に local/simtunnel は無いため CLI はフルパスか PATH 上のコマンドで叩く）
cd <アプリ repo の作業ディレクトリ> && ~/ghq/github.com/bannzai/simtunnel/local/simtunnel up <session> --wait
# 明示指定（どのディレクトリからでも可）
SIMTUNNEL_REPO=<owner>/<repo> local/simtunnel up <session> --wait
```

**既定 repo（`bannzai/simtunnel`）へのフォールバックはしない。** 対象 repo が決まらない場合はエラーで停止する。フォールバックすると `up` した repo と別の repo を検索することになり、`down` が「実行中 run はない」と冪等成功で空振りして runner を掴んだまま放置される（実測: bannzai/mementomorning で `up` したセッションを、`SIMTUNNEL_REPO` なしの `down` が既定 repo を見て取りこぼした）。同じ理由で、対象 repo は実行のたびに標準エラーへ表示する。

#### 起動引数を caller から渡す: `workflow_dispatch` の `type: choice`（固定選択肢）

セッション開始時から効かせたい起動引数（アプリ起動前に読まれる設定など。セッション開始後なら agentd の `relaunch` で足りる）は caller workflow から渡す。**自由入力（`type: string`）は採らない**。

**推奨は `type: choice`（固定選択肢）方式**:

- 選択肢に無い値は GitHub 側で dispatch が拒否されるため、自由文字列が workflow に流入する経路が構造的に無い
- 選択肢の実値（実際に `simctl launch` へ渡す引数列）は workflow 内にハードコードし、input 値は選択肢のキーとしてだけ使う。`run:` への `${{ }}` 直接展開はしない
- 1 ファイルに収まり、バリエーション追加は選択肢 1 行 + 対応する引数列の追記で済む

```yaml
on:
  workflow_dispatch:
    inputs:
      launch_preset:
        description: "起動引数のプリセット"
        type: choice
        default: none
        options: [none, onboarding-done, premium]

jobs:
  session:
    steps:
      # input 値は case のキーとしてだけ使い、引数列は workflow 内のハードコードから選ぶ
      - env:
          LAUNCH_PRESET: ${{ inputs.launch_preset }}
        run: |
          case "$LAUNCH_PRESET" in
            onboarding-done) ARGS=(-ONBOARDING_DONE 1) ;;
            premium) ARGS=(-PREMIUM 1) ;;
            *) ARGS=() ;;
          esac
```

代替として「バリエーションごとに caller workflow を分ける」（ファイルそのものが許可リストになる）方式も同等の安全性を持つ。バリエーションが少なく、それぞれ別の名前で dispatch したい場合はこちらでもよい。

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
    permissions:
      contents: read # checkout のみ。OIDC token (id-token) は session job だけに与える
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
    permissions:
      id-token: write # Tailscale の OIDC 認証に必要
      contents: read
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

#### オンボーディング突破用 Maestro flow の自動実行

多くのアプリは初回起動時にオンボーディングがあり、毎セッション MCP の tap で突破するのは非効率。定型の突破を Maestro flow に任せ、以降の探索的な操作を WDA / MCP で行う。

- **runner 上で実行する**: maestro は WDA を使わず、自前の XCUITest ドライバを simctl で install する方式のため、ローカルから tailnet 越しの remote Simulator に対しては実行できない（公式 docs もローカル Xcode CLT 前提。https://docs.maestro.dev/get-started/supported-platform/ios.md ）
- **自動検出（input なし）**: caller repo に `.maestro/flows/simtunnel/setup.yml` があれば実行、なければスキップ。無効化はファイルを消す / リネームする運用。既存 flow をそのまま使えるなら **symlink**（git は symlink を保持する）、launch 条件の制御が要るなら `launchApp` + `runFlow` で既存 flow を包む**薄いラッパー flow** を置く
- **システムダイアログの文言分岐は permissions 事前許可で回避する**: runner の Simulator は英語ロケールのため、`tapOn: "許可"` のような日本語文言の条件タップは通らない（実測: 通知許可ダイアログが "Allow" で表示され flow が失敗）。setup.yml 側で `launchApp` の `permissions`（例: `notifications: allow`）を使いダイアログ自体を出さない
- **実行順序はアプリ install / launch 後 → WDA 起動前**: maestro のドライバも WDA も XCUITest runner のため同時併用できない。直列に実行して干渉を避ける
- **flow が失敗してもセッションは開く**: flow は補助であり、失敗してもセッション自体の価値は残る。失敗（maestro CLI のインストール失敗含む）は run summary に警告を出して WDA 起動へ進む
- 実装は `runner/run-maestro.sh`（maestro CLI のインストール込み。caller repo の workspace ルートで実行される）

## macOS アプリの操作（WebDriverAgentMac）

iOS / iPad は Simulator 上の WDA で操作するが、macOS アプリは Simulator ではなく runner の GUI セッション（Aqua / WindowServer）で直接動く。トンネル・ephemeral・ACL・OIDC・`workflow_dispatch` のみ・SHA 固定といった安全性設計は iOS 版とそのまま共有し、**操作レイヤーだけ macOS 用に差し替える**。

### 操作レイヤーの選定: WebDriverAgentMac（appium-mac2-driver 同梱）

候補（XCUITest 直書き / Accessibility API 直叩き / AppleScript・System Events / cliclick + screencapture）を比較し、**WebDriverAgentMac** を採る。理由:

- iOS 版と同じ WDA HTTP API（W3C WebDriver 準拠 + 拡張）で喋れるため、curl ベースの操作・simtunnel-mcp 互換レイヤーの考え方をそのまま横展開できる。必要な操作（起動 / クリック / キー入力 / スクリーンショット / アクセシビリティツリー / URL open）が 1 つの HTTP サーバで揃う
- XCUITest ベースのため要素検索（accessibility id / predicate / class chain / xpath）と機能的検証が可能。cliclick + 画像だけの方式より壊れにくい
- appium 本体は不要。同梱の `WebDriverAgentMac.xcodeproj`（scheme `WebDriverAgentRunner`）を `xcodebuild build-for-testing` + `test-without-building` で単体起動できる（`USE_PORT` でポート指定）。iOS 版 `start-wda.sh` と同じキャッシュ戦略が使える

主なエンドポイント（実測で確認したもの）:

| 操作 | エンドポイント |
|---|---|
| 死活確認 | `GET /status` |
| スクリーンショット | `GET /screenshot`（base64。session 不要） |
| セッション作成 | `POST /session` `{"capabilities":{"alwaysMatch":{"appium:bundleId":"<id>"},"firstMatch":[{}]}}` |
| 要素検索 | `POST /session/:id/element` `{"using":"accessibility id","value":"<id>"}` |
| クリック | `POST /session/:id/element/:uuid/click` |
| 値の設定（入力） | `POST /session/:id/element/:uuid/value` `{"value":["..."]}` |
| 属性取得 | `GET /session/:id/element/:uuid/attribute/:name` |
| アクセシビリティツリー | `GET /source?format=xml`（**`format=json` は非対応**。`xml` か `description` のみ） |

### iOS 版との違い

- **1 GUI セッション = 1 WDA**。macOS runner は GUI セッションが 1 つなので Simulator 台数のような多重化はしない（ポートは 8100 固定）
- **アプリ起動は LaunchServices 登録 + bundleId セッション**。ビルドした .app を `lsregister -f` で登録し、`appium:bundleId` でセッションを作ると WDA が起動・前面化まで行う（既存インスタンスは terminate して起動し直す）。iOS の simctl install/launch に相当
- **スクリーンショットは `GET /screenshot` を既定にする**。macOS では serve-sim / MJPEG は使わない。ローカルからの取得は DERP relay 経由でも 1 枚 1 秒前後（iOS の PNG `/screenshot` が 68 秒だったのと違い、実用範囲）
- **入力（value 設定）はフォーカス非依存で通るが、click は座標ヒットテスト**。前面に他ウィンドウ（特にモーダル）があると click 対象が `not hittable` で失敗する

### ハマりどころ（実測）

- **`screencapture` を使わない**。`screencapture` を runner で実行すると ScreenCaptureKit の許可ダイアログ（"bash is requesting to bypass the system private window picker…"）が画面中央にモーダルで出て、その裏のボタンが `not hittable` になり click が失敗する。画面取得は WDA の `GET /screenshot` で行えばこのダイアログは出ない（実測: screencapture 併用時 click 失敗 → 廃止後 click 成功）
- **SIP は runner 上で無効**（`csrutil status` = disabled を macos-15 / macos-26 で確認）。このため XCUITest の自動化許可・アクセシビリティが追加設定なしで通る。`automationmodetool` / `DevToolsSecurity` / TCC.db 書き換えは不要だった
- runner には Aqua の console session がある（`scutil` の `State:/Users/ConsoleUser` が `runner`）。GUI アプリは問題なく描画・操作できる

### 実測値（2026-08-10）

WebDriverAgentMac v4.1.1 / サンプル `macOSProject`（swiftc ビルドの最小 SwiftUI アプリ）。

| 項目 | macos-15 (Xcode 16.4) | macos-26 (Xcode 26.6) |
|---|---|---|
| WDA-mac 起動（キャッシュミス / clone + build 込み） | 約 39 秒 | 約 58 秒 |
| WDA-mac 起動（キャッシュヒット） | 約 10 秒 | 約 15 秒 |
| `GET /screenshot`（runner ローカル / PNG 約 95〜210KB） | 126〜175ms | 288〜322ms |
| セッション作成（runner ローカル） | 約 1.4 秒 | 約 2.1 秒 |
| click（runner ローカル） | 約 0.4〜0.6 秒 | 約 0.6 秒 |
| value 入力（runner ローカル） | 約 0.8 秒 | 約 3.3 秒 |

ローカル（tailnet / DERP relay 経由。macos-15 セッション）: `GET /screenshot` 約 0.9 秒 / セッション作成 約 2.1 秒 / click 約 1.3 秒 / value 入力 約 1.8 秒。制御系はすべて 1〜2 秒台で実用範囲。

機能的検証（click → `statusLabel` が `Clicked!` に変化 / value 入力 → `inputEcho` が `input: hello` に変化）を macos-15 / macos-26 の両 runner とローカル tailnet 経由で確認済み。

### 各アプリ repo での実行（reusable workflow）

iOS 版と同じく `macos-session.yml`（`workflow_call`）を各アプリ repo の薄い caller workflow から呼ぶ。simtunnel 自身は `macos-app-session.yml`（`workflow_dispatch` ラッパー）経由で呼ぶ。

```yaml
name: macos-app-session
run-name: "session=${{ inputs.session }} runner=${{ inputs.runner }}"
on:
  workflow_dispatch:
    inputs:
      session: { required: true, default: dev-mac }
      device: { required: false, default: "-" } # local/simtunnel 互換のため（macOS では未使用）
      duration_minutes: { required: true, default: "30" }
      runner: { required: false, default: macos-15 }
jobs:
  session:
    permissions:
      id-token: write
      contents: read
    uses: bannzai/simtunnel/.github/workflows/macos-session.yml@<commit SHA> # main
    with:
      session: ${{ inputs.session }}
      runner: ${{ inputs.runner }}
      duration_minutes: ${{ inputs.duration_minutes }}
      build_project: MyMacApp.xcodeproj
      build_scheme: MyMacApp
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
```

ローカル CLI は iOS 版と同じものを流用できる（`macos-app-session.yml` は `device` input を宣言済みのため `up` がそのまま通る）。macOS では WDA 操作を curl か skill の `macos-wda.sh` で行う:

```bash
SIMTUNNEL_REPO=<owner>/<repo> SIMTUNNEL_WORKFLOW=macos-app-session.yml local/simtunnel up <session> --wait
SIMTUNNEL_REPO=<owner>/<repo> SIMTUNNEL_WORKFLOW=macos-app-session.yml local/simtunnel down <session>
```

- `status` / `down` は接続先非依存で macOS セッションにもそのまま効く。**`local/simtunnel screenshot` は :9100 の MJPEG を取得する実装のため macOS では使えない**（WDA-mac は MJPEG を提供しない）。画面取得は WDA の `GET /screenshot`（:8100）を curl か skill の `macos-wda.sh screenshot` で行う。serve-sim を使う `preview` も macOS では使わない
- 使い方・制約・`macos-wda.sh` の詳細は castle の `macos-simtunnel` skill を参照

## Tailscale セットアップ手順（Phase 0 実施記録）

管理コンソールでの操作。**順序厳守（ACL が先。「リポジトリ公開に耐える安全性」の 5 を参照）**。

### 1. ACL の設定

https://login.tailscale.com/admin/acls

JSON editor に切り替え、ポリシーファイル全体を上記「リポジトリ公開に耐える安全性」の grants 構文の方針で編集して Save する。注意: コメントに非 ASCII 文字を使うと、貼り付け時に parse error になることがある（実際になった）。コメントは英語で書く。

### 2. Trust credential の発行（OIDC）

https://login.tailscale.com/admin/settings/trust-credentials

1. **New credential** → credential type で **OpenID Connect** を選択
2. Issuer: **GitHub** / Subject: GitHub が OIDC token で送る subject に一致する値を入れる。現行形式（2026-08-13 実測）は owner とリポジトリ名それぞれに `@<ID>` が付く `repo:<owner>@<owner_id>/<repo>@<repo_id>:*`（複数 repo をカバーする場合はワイルドカード `repo:<owner>@<owner_id>/*` も可。検証済み。トレードオフは「各アプリ repo での実行」参照）。owner_id は `gh api user --jq .id`（org は `gh api orgs/<org> --jq .id`）、repo_id は `gh api repos/<owner>/<repo> --jq .id` で取得できる
3. Scopes: **Custom scopes** のまま一覧を下にスクロールし、**Keys > Auth Keys** の **Write** にチェック → タグは **tag:ci** を選択
4. 発行された **Client ID** と **Audience** を控える（OAuth client と違い secret は存在しない）

subject の形式は GitHub 側の変更で変わり得る（実例: 2026-08-13 に `repo:<owner>/<repo>:...` から `@<ID>` 付きの現行形式へ変わり、旧形式の Subject では認証エラーになった。issue #34）。形式が合っているかは推測せず、**admin console の credential 画面に表示される「Received "..." from issuer」の実値を正として Subject を合わせる**。

認証エラーの切り分け:

- **401**（`failed to exchange JWT for access token: token exchange failed with status 401: {"message":"federated identity invalid"}`）= credential 不一致。Subject を確認する
- **403** Unauthorized = Subject は一致したが scope/tag 不足、または subject の再検証失敗。admin console の credential 画面に「Cannot validate subject」と issuer から届いた実際の subject（`Received "..." from issuer`）が表示されるので、その実値に合わせる

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
│   ├── simulator-session.yml         # workflow_dispatch: simtunnel 自身用の薄いラッパー（session.yml を呼ぶ）
│   ├── macos-session.yml             # reusable workflow (workflow_call): macOS アプリセッションの実体（WDA-mac）
│   ├── macos-app-session.yml         # workflow_dispatch: macOS 用の薄いラッパー（macos-session.yml を呼ぶ）
│   └── macos-app-spike.yml           # workflow_dispatch: macOS アプリ対応の go/no-go スパイク（issue #23 / 検証専用）
├── iOSProject/                       # iOS サンプルアプリ（SwiftUI + SwiftData / deployment target iOS 26.x）
├── macOSProject/                     # macOS サンプルアプリ（swiftc ビルドの最小 SwiftUI。操作結果を accessibilityIdentifier に反映）
├── runner/                           # GHA 側スクリプト
│   ├── boot-simulator.sh             # simctl boot + 起動待ち（複数ランタイム時は最新 iOS を優先）
│   ├── macos-app-spike.sh            # macOS アプリ対応スパイクの実体（WebDriverAgentMac 単体起動 + 操作の実測）
│   ├── install-app.sh                # app_zip_url の .app を install / launch（未指定ならスキップ）
│   ├── install-artifact-app.sh       # app_artifact（caller build job の成果物）の .app を install / launch
│   ├── build-app.sh                  # build_project / build_scheme を runner 上でビルドして install / launch
│   ├── build-macos-app.sh            # macOS アプリ（サンプル or build_project）をビルドして .app パス / bundle id を出力
│   ├── launch-macos-app.sh           # ビルド済み .app を LaunchServices 登録して起動（bundleId セッション用）
│   ├── run-maestro.sh                # caller repo の .maestro/flows/simtunnel/setup.yml を自動検出して実行（無ければスキップ）
│   ├── start-wda.sh                  # iOS WDA を build-for-testing（キャッシュ対応）+ test-without-building で起動
│   ├── start-wda-mac.sh              # WebDriverAgentMac を runner の GUI セッション上で起動（iOS 版の macOS 対応）
│   ├── start-serve-sim.sh            # serve-sim を起動（ブラウザ操作 UI + ライブ映像を :3200 で配信）
│   ├── agentd.py                     # simtunnel-agentd: 許可した simctl 動詞だけを :8200 で受ける HTTP サーバ
│   ├── start-agentd.sh               # agentd.py をバックグラウンド起動して :8200 の応答を待つ
│   ├── test/test-agentd.py           # agentd の許可リスト検証（xcrun をスタブに差し替えて実行）
│   ├── bridge.sh                     # socat: tailscale IF → 指定ポート（直接到達可能ならスキップ）
│   └── keepalive.sh                  # duration_minutes までジョブを維持（WDA 死活監視付き）
├── local/
│   └── simtunnel                     # ローカル CLI: up / down / list / status / screenshot / record / preview / wait
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
- [x] simtunnel-agentd（完了: 2026-08-17）: runner 上の HTTP 受け口（:8200 / tailnet 内限定）で、許可した simctl の動詞だけを遠隔実行する（設計:「simtunnel-agentd」）。当初想定していた「.app を zip で転送 → install → launch」は per-repo 展開でアプリを各 repo の runner がビルドするようになったため実装せず、WDA では届かない領域（起動引数・通知・権限・ステータスバー）に絞った
  - 検証（実 run / iPhone 17 / simulators=1）: 許可した 5 動詞がすべて 200（`status_bar override` は `9:41` / 電池 100% / 4 本アンテナがスクリーンショットに反映、`relaunch` はアプリが前面に戻ることを確認、`record/stop` は runner 上のパスとサイズを返した）。許可外・不正入力は `spawn` / `openurl` が 404、`udid` 指定・範囲外 slot・不正な起動引数・未知のキー・`aps` の無い payload・列挙外の privacy service・範囲外の status_bar 値が 400、セッション外の bundleId が 403
  - ローカル検証: `python3 runner/test/test-agentd.py`（`xcrun` をスタブに差し替えて 18 ケース）
- [x] クライアント側録画 `simtunnel record`（完了: 2026-08-17）: MJPEG (:9100) をローカルに録画する（設計:「画面の録画」）
  - 検証（実 run / 2 本）: 25 秒の録画で 229 フレーム（9.2 fps / 13.2MB）と `--mp4` の ffmpeg 変換を確認。別の約 19 秒の録画（81 フレーム / 4.2 fps）で、録画中に起こした画面遷移（アプリ → ホーム画面）が 64 フレーム目として特定できることを確認
- [x] 1 runner 複数 Simulator（完了: 2026-07-07）: `simulators` input で台数指定。2 台目以降はデバイスの clone を boot し、i 台目の WDA に per-sim の xctestrun コピーで `USE_PORT=8100+i` / `MJPEG_SERVER_PORT=9100+i` を注入する。CLI / mcp-config は `--slot` で台を指定。simulators=2 の実 run で両ポート HTTP 200・サンプルアプリ両台 install・slot 1 のみ tap して独立性をスクリーンショットで確認。ハマり: xctestrun のコピーは `__TESTROOT__` 相対で成果物を参照するため、元と同じディレクトリに置く必要がある。3 台以上のメモリ成立性は未検証
- [x] serve-sim の複数 Simulator 対応（完了: 2026-07-10）: serve-sim は 1 プロセスで複数 UDID を配信できる（CLI が可変長で UDID を受け、デバイスごとの view は `/?device=<UDID>`、ストリームは `/helper/<UDID>/stream.mjpeg`、一覧は `/grid/api`。すべて :3200）ため、slot ごとの多重起動ではなく **全 UDID を 1 プロセスに渡す方式**を採用。tailnet への公開ポートは :3200 のまま増えず、多重起動によるメモリ増も避けられる（「リポジトリ公開に耐える安全性」の範囲内）
  - `local/simtunnel preview <session> --slot <i>` は `/grid/api` の一覧から clone 命名（boot-simulator.sh の `<デバイス名> simtunnel-<slot+1>`）で UDID を引き当て、`?device=` 付き URL を開く。slot 0 は既定表示のため解決不要
  - `/grid/api` と `?device=` は serve-sim の内部仕様（バージョン未固定）に依存する。preview が壊れたら serve-sim 側の変更を疑う
  - 検証（simulators=2 の実 run）: 1 プロセス（:3200）から両 UDID の `/helper/<UDID>/health` HTTP 200、`?device=` による対象デバイスの切り替え、slot 1 の `/helper/<UDID>/stream.mjpeg` から DERP relay 経由でライブフレーム 17 枚（45 秒間）の取得、サマリへの slot ごとの preview URL 出力を確認。`preview --slot` の UDID 解決も実セッションで確認
  - ハマり: `/grid/api` の初回コールは一覧が温まっておらず空を返すことがある（2 回目以降は runner 上の全 Simulator を返す）。`preview --slot` はリトライ + `state == "Booted"` フィルタで吸収

### Phase 5: 各アプリ repo への展開
- [x] reusable workflow 化（完了: 2026-07-06）: `session.yml`（workflow_call）+ `simulator-session.yml`（dispatch ラッパー）に分割。ビルド対象を input 化（`build_project` / `build_scheme` / `build_configuration`）。runner スクリプトは `github.job_workflow_sha` で同一 commit を checkout。ローカル CLI は `SIMTUNNEL_REPO` / `SIMTUNNEL_WORKFLOW` で対象 repo を切り替え（詳細:「各アプリ repo での実行」）
- [x] Tailscale trust credential の subject ワイルドカード検証（完了: 2026-07-06）: subject ワイルドカード（`repo:<owner>/*` 形式）の credential で、caller repo が異なる run（SimTunnelDemoProject）の認証が通ることを確認
- [x] SwiftUI 実験 repo（bannzai/SimTunnelDemoProject）で実戦（完了: 2026-07-06）: caller workflow + Secrets をセットアップし、up → status 200 → mcp-config → mobile-mcp 互換ツールで tap / screenshot / HOME / launch_app → down の一連を確認（記録: SimTunnelDemoProject PR #1 のコメント）。`local/simtunnel` は `up` だけでなく `down` / `list` も対象 repo の解決が必要（当時は `SIMTUNNEL_REPO` の明示が必須。2026-08-14 以降はカレントディレクトリからの解決に対応。詳細:「各アプリ repo での実行」）
- [x] Maestro flow の自動実行（完了: 2026-07-07）: caller repo の `.maestro/flows/simtunnel/setup.yml` を自動検出し、アプリ install / launch 後・WDA 起動前に runner 上で実行（設計:「オンボーディング突破用 Maestro flow の自動実行」）。Pilll 実 run でオンボーディング突破 → 直後の WDA 操作（tap）に干渉が無いことを確認（記録: simtunnel PR #19 コメント）。実測: maestro step 全体 約 6 分（CLI インストール約 30 秒 + ドライバ起動約 2 分 + flow 実行約 4 分）、setup.yml が無い repo でのスキップは約 0.6 秒。flow 失敗時に警告のみでセッションが開くことも実 run で確認済み
- [x] Flutter (bannzai/Pilll) への展開（完了: 2026-07-06）: 「build job 分割 + artifact 渡し」方式で caller workflow を追加。build（`make secret` → flutter build --simulator）約 10 分 + セッション準備で、dispatch → 操作可能まで約 15 分。MCP 経由の tap（OS アラート / アプリ内ボタン → ボトムシート表示）とスクリーンショットを実 run で確認（記録: Pilll PR #1812 のコメント）。序盤 2 回の run は keepalive 早期終了（「未検証事項・リスク」参照）に当たり、keepalive 強化後の run で安定

### Phase 6: macOS アプリ対応（完了: 2026-08-10）
- [x] 操作レイヤーの選定: WebDriverAgentMac（appium-mac2-driver 同梱）を採用（設計:「macOS アプリの操作（WebDriverAgentMac）」）
- [x] GHA macos runner の GUI セッション調査: SIP 無効 / Aqua console session あり / GUI アプリ描画可を macos-15・macos-26 で確認
- [x] `macos-session.yml`（workflow_call）+ `macos-app-session.yml`（dispatch ラッパー）+ runner スクリプト（`start-wda-mac.sh` / `build-macos-app.sh` / `launch-macos-app.sh`）。`bridge.sh` / `keepalive.sh` はポート引数を取るため無改修で流用
- [x] PoC: サンプル `macOSProject` を runner でビルド → WDA-mac 起動 → tailnet 越しにローカルから screenshot 取得・click・value 入力を実行し、機能的検証（`statusLabel` → `Clicked!` / `inputEcho` → `input: hello`）まで確認（実測値は「macOS アプリの操作」参照）
- ハマり: `screencapture` が ScreenCaptureKit 許可ダイアログを出しボタンを覆って click が失敗する → 画面取得は WDA `GET /screenshot` に統一して解消
- 使い方・制約・実測値・ハマりどころは castle の `macos-simtunnel` skill に集約

## 未検証事項・リスク

- ~~WDA の bind interface~~: **解決済み（Phase 1 実測）**。Simulator 上の WDA は 8100/9100 を全インターフェースで listen し、bridge は不要だった。挙動が変わった時の保険として bridge.sh は残す（到達可能なら何もしない）
- **転送帯域**: GHA runner ↔ ローカル間は direct 接続が確立せず DERP relay 経由（Phase 1 実測）。制御系 API（tap / 入力 / status）は 0.5〜2 秒で実用範囲だが、大きなレスポンスの転送は遅い。スクリーンショットは MJPEG フレーム抽出で回避。`.app` 転送（Phase 4）はこの帯域がボトルネックになる可能性が高い
- ~~WDA 起動時間~~: **解決済み（Phase 4）**。ビルドキャッシュ導入で dispatch → 操作可能は約 2.8 分（キャッシュヒット時）
- **`down` 直後の同名セッション再起動**: 実測（2026-07-07）では ephemeral node は cancel 送信の約 20 秒後に tailnet から消えた。ただし再 up を実際にブロックするのは run のキャンセル完了待ちで、cancel 送信後もしばらく（数十秒〜1 分程度）GitHub API 上は run が in_progress のままのため、`up <同名>` は「run はすでに起動中」の冪等チェックに当たって何もしない。`simtunnel list` で run が completed になったのを確認してから `up` する。作り直しが目的なら `up <session> --force` が既存 run のキャンセル → run の終了待ち → node 登録の消滅待ち → 再 dispatch までを一括で行う
- **同時実行上限**: Free プランは macOS 5 並列。worktree を跨いだ総セッション数の上限になる。実測済み（2026-07-07: repo 横断で 5 job が in_progress の状態で追加 dispatch した job は queued のまま待機し、スロットが空くと自動で開始した。上限はセッション用 workflow に限らず、同一アカウントの全 macOS job（他 workflow の run 含む）で共有される）
- **repo を跨いだ同名セッション**: 同時起動防止の concurrency group は repo 単位のため、別 repo で同名セッションを起動すると tailnet ホスト名 `simtunnel-<session>` が衝突する。実測（2026-07-07）では後から join したノードに `-1` が付き（`simtunnel-<session>-1`）、`simtunnel-<session>` の名前解決は先着ノードを指し続けるため、**CLI は別 repo の先着セッションに黙って接続する**（エラーにならないのが危険）。repo ごとに接頭辞を変える等、セッション名の一意性は運用で担保する
- **Runner スペック**: GitHub-hosted macOS (arm64) はメモリが小さめ。1 runner 複数 Simulator は 2 台（サンプルアプリ + serve-sim なし）で成立を実測済み（Phase 4）。3 台以上や重いアプリでの成立性は要検証
- **MagicDNS の伝播ラグ**: ephemeral node の tailnet 参加後、`simtunnel-<session>` の名前解決ができるまで数分かかることがある（実測 2026-07-06。IP 直なら即到達可能）。`.mcp.json` のホスト名接続が ready 直後に ENOTFOUND になったら少し待って再試行する。OS の resolver（dscacheutil）は解決できているのに Node の fetch だけ失敗が続く事例も観測した（2026-07-07）。急ぐ場合は `SIMTUNNEL_WDA_URL` を IP 直（`tailscale status` で取得）にすれば確実に繋がる
- **keepalive 中の WDA 無応答**: keepalive の死活チェックが失敗し run が failure 終了する事象を計 3 回観測（2026-07-06: simtunnel 本体で開始 5 秒後 x1、Pilll で開始 約5 分後 / 35 秒後 x2）。重いアプリ（Flutter + Firebase の Pilll）のセッションで発生率が高く、runner のメモリ圧が疑わしい（GitHub-hosted macOS runner は RAM が小さい）。対策として keepalive は連続 4 回失敗した時だけ終了し、終了時に wda.log 末尾を出力する。**対策の効果を実測済み**（2026-07-06: Pilll + serve-sim 有効のセッションで開始 25 秒後に無応答 1 回 → 回復 → ブラウザ preview 利用込みで 60 分完走。無応答は一時的なストールで、連続失敗しきい値で吸収できる）。セッションが早期に消えたら run の failure step と wda.log を確認し、再度 `up` する。切り分け用に caller で `serve_sim: "false"` にしてメモリ消費を減らす手もある
