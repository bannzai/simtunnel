# simtunnel

GitHub Actions の macOS Runner 上で iOS Simulator + WebDriverAgent を起動し、Tailscale 経由でローカルの Claude / Codex から操作・スクリーンショット取得するためのツール群。

## ドキュメント
- 設計・採用理由・実装フェーズの SSOT は PROJECT.md。設計に関わる変更をしたら同じ変更で PROJECT.md も更新する

## 前提
- public リポジトリで運用する（macOS Runner 無料）。tailnet 内の実 IP 等の環境固有情報を書かない（参照: PROJECT.md「リポジトリ公開に耐える安全性」）
- Tailscale への認証は OIDC（workload identity federation）。GitHub Secrets は `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`（識別子であり長期シークレットではない）
- WDA は無認証のため、到達経路は tailnet 内に限定する。公開トンネル（cloudflared / ngrok 等）へ変更する場合は PROJECT.md「リポジトリ公開に耐える安全性」の再検討とセットで行う（参照: PROJECT.md 設計判断）
- workflow のトリガーは `workflow_dispatch` のみとする（fork PR に Secrets を渡さないため。参照: PROJECT.md 設計判断）

## セッション操作
- `local/simtunnel` CLI を使う: `up <session> [--wait]` / `down <session>` / `list` / `status <session>` / `screenshot <session>`（オプションはスクリプト冒頭の使い方を参照）
- 放置しても `duration_minutes`（既定 60 分）で自動終了する

## サンプルアプリ
- `iOSProject/`（SwiftUI + SwiftData）。セッション起動時に runner 上でビルドされ launch まで行われる。無効化は `gh workflow run` で `-f sample_app=false`
- deployment target が iOS 26.x のため runner は macos-26 固定。デバイスは iPhone 17 系を使う

## 検証
- セッション疎通: `local/simtunnel status <session>` が HTTP 200 を返すこと
- スクリーンショット: `local/simtunnel screenshot <session>` で ./tmp に保存して Read する。`GET /screenshot` は DERP relay 経由だと 1 分超かかるため使わない（参照: PROJECT.md「Phase 1 実測」）
