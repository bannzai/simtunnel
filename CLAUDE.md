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
- 起動: `gh workflow run simulator-session.yml -R bannzai/simtunnel -f session=dev -f duration_minutes=60`
- 停止: `gh run cancel <run-id> -R bannzai/simtunnel`（放置しても duration_minutes で自動終了）

## 検証
- セッション疎通: `curl http://simtunnel-<session>:8100/status` が 200 を返すこと
- スクリーンショット: `:9100` の MJPEG からフレームを抽出して確認する（./tmp に保存して Read する）。`GET /screenshot` は DERP relay 経由だと 1 分超かかるため使わない（参照: PROJECT.md「Phase 1 実測」）
