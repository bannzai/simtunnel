# リポジトリのメモ

- [GitHub REST の commits・contents endpoint はクォータが残っていても 403 を返すことがあるため、SHA の解決は git ls-remote、ファイルの取得は raw.githubusercontent.com を先に使う](github-rest-commits-contents-403-with-remaining-quota.md) — `gh api` の commits・contents が「API rate limit exceeded」の 403 を返した時、コミットの SHA の解決やリポジトリ上のファイルの取得をスクリプトに書く時
