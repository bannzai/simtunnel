# simtunnel

GitHub Actions の macOS Runner 上で iOS Simulator + WebDriverAgent を起動し、Tailscale 経由でローカルの Claude / Codex から操作・スクリーンショット取得するためのツール群。

## ドキュメント
- 設計・採用理由・実装フェーズの SSOT は PROJECT.md。設計に関わる変更をしたら同じ変更で PROJECT.md も更新する

## 前提
- このリポジトリは public 前提で運用する（macOS Runner が無料。private だと消費分数 10 倍）
- Tailscale の OAuth client の値は GitHub Secrets（`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`）にのみ置く
- WDA は無認証のため、到達経路は tailnet 内に限定する。公開トンネル（cloudflared / ngrok 等）へ変更する場合は PROJECT.md「public リポジトリでの安全性」の再検討とセットで行う（参照: PROJECT.md 設計判断）
- workflow のトリガーは `workflow_dispatch` のみとする（fork PR に Secrets を渡さないため。参照: PROJECT.md 設計判断）

## 検証
- セッション疎通: `curl http://simtunnel-<session>:8100/status` が 200 を返すこと
- スクリーンショット: `GET /screenshot` の base64 をデコードして画像を確認する（./tmp に保存して Read する）
