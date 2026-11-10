---
scope: cross-repository
recorded: 2026-11-10
---
# GitHub REST の commits・contents endpoint はクォータが残っていても 403 を返すことがあるため、SHA の解決は git ls-remote、ファイルの取得は raw.githubusercontent.com を先に使う

2026-08-14 の PR #36 の検証中に実測した事象:

- `gh api repos/<owner>/<repo>/commits/<ref>` と `gh api repos/<owner>/<repo>/contents/<path>` が「API rate limit exceeded」の 403 を返し続けた
- 同じ時刻の `gh api rate_limit` は core の remaining が 4900 以上で、`gh run list`・`gh run cancel`・GraphQL は通った (特定の REST endpoint だけが弾かれた)

2026-11-10 の再確認 (対象は bannzai/simtunnel の main):

- `gh api rate_limit --jq .resources.core` は remaining 4486 で、`gh api repos/<owner>/<repo>/commits/main` と `gh api repos/<owner>/<repo>/contents/LICENSE` は 403 にならず SHA を返した。403 は常に出るものではなく、この日は再現していない
- `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<repo>.git refs/heads/main` は `gh api` の commits と同じ SHA を返した
- `curl -sfL -m 10 https://raw.githubusercontent.com/<owner>/<repo>/main/LICENSE` は HTTP 200 を返した

**なぜ:** 403 が出た原因は特定できていない (残クォータがあるのに出たことだけを実測した)。`local/simtunnel` の `up --ref` は ref の SHA の解決 (`resolve_ref_sha`) と、ref 上の workflow ファイルの有無の確認 (`workflow_dispatchable_on_ref`) を行う。PR #36 ( https://github.com/bannzai/simtunnel/pull/36 ) はこの事象を理由に、2 つの関数を REST API を通らない経路を先に試し、取れない時だけ `gh api` で補う実装にした。

**どう使う:** コミットの SHA の解決は `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<repo>.git` を、ファイルの取得は `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>` を先に使い、`gh api` は取れなかった時の補いにする。`gh api` の commits・contents が「API rate limit exceeded」の 403 を返したら、`gh api rate_limit` の残量を見て、残っていればこの事象として上の経路に切り替える。
