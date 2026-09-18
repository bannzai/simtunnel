# simtunnel

Run iOS Simulators (and macOS apps) on GitHub Actions macOS runners and drive them from the Claude Code / Codex sessions on your own Mac.

Your local machine boots zero simulators. Each session is one GitHub Actions job that joins your Tailscale tailnet as an ephemeral node, so your AI agents talk to WebDriverAgent over plain HTTP at a fixed hostname. Standard GitHub-hosted runners are free for public repositories, macOS included.

```text
Local Mac
├─ worktree A: Claude Code ─→ http://simtunnel-a1:8100 (WebDriverAgent)
├─ worktree B: Codex       ─→ http://simtunnel-b1:8100
└─ Tailscale client (only reachable inside your tailnet)
        │  encrypted P2P / no public endpoint
GitHub Actions (workflow_dispatch)
├─ job session=a1: macOS runner
│   ├─ iOS Simulator
│   ├─ WebDriverAgent   :8100  tap / swipe / type / screenshot / accessibility tree
│   ├─ MJPEG stream     :9100  live screen, recordable from the client
│   ├─ simtunnel-agentd :8200  allow-listed simctl verbs (relaunch / push / privacy / status bar)
│   └─ tailscale ephemeral node, hostname simtunnel-a1
└─ job session=b1: same
```

## Why

Parallel AI-driven iOS development eats Macs. Every worktree wants its own simulator, and a handful of them makes a laptop unusable. simtunnel moves the simulators to GitHub's macOS runners: one job per session, up to the plan's concurrency limit, each auto-terminating after `duration_minutes`.

## How it works

1. `simtunnel up <session>` dispatches a workflow in your app repository.
2. The runner boots a simulator, builds and installs your app, starts WebDriverAgent, and joins your tailnet via OIDC (workload identity federation, no long-lived secrets).
3. Your local agent hits `http://simtunnel-<session>:8100`. Everything needed for UI testing is a WebDriver HTTP call.
4. `simtunnel down <session>` cancels the run. The ephemeral node disappears from the tailnet. `timeout-minutes` is the safety net if you forget.

## Requirements

- A Tailscale tailnet (the free Personal plan is enough) and the Tailscale client on your Mac
- `gh` CLI authenticated to the account that owns the app repository
- The app repository must be public if you want the macOS minutes to be free (private repositories bill macOS at roughly 10x the Linux rate)
- `node` for the MCP server, `ffmpeg` only if you want `record --mp4`

## Setup

Full details, including the exact ACL policy and OIDC subject format, are in [PROJECT.md](PROJECT.md). The order matters: configure the ACL before the first runner ever joins.

1. **Tailscale ACL.** Define `tag:ci`, allow your devices to reach `tag:ci` on ports 8100+ / 9100+ / 8200 / 3200, and deny everything originating from `tag:ci`. A runner that gets compromised must not be able to reach anything else in your tailnet.
2. **Trust credential (OIDC).** In the Tailscale admin console create an OpenID Connect credential with issuer GitHub, a subject matching your repository (or `repo:<owner>@<owner_id>/*` to cover all of them), scope Auth Keys: Write, tag `tag:ci`. Note the Client ID and Audience. Neither is a secret.
3. **GitHub Secrets.** Set `TS_OIDC_CLIENT_ID` and `TS_OIDC_AUDIENCE` on the app repository.
4. **Caller workflow.** Add a thin `workflow_dispatch` workflow to the app repository that calls the reusable `session.yml` from this repository. Pin it to a commit SHA.

```yaml
name: simulator-session
# local/simtunnel finds the run by this run-name, keep the format
run-name: "session=${{ inputs.session }} device=${{ inputs.device }}"

on:
  workflow_dispatch:
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
    permissions:
      id-token: write # Tailscale OIDC
      contents: read
    uses: bannzai/simtunnel/.github/workflows/session.yml@<commit SHA>
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

Apps that need a custom build (Flutter, secret restoration, SDK setup) build in their own job, upload the `.app` as an artifact, and pass it through the `app_artifact` input. See PROJECT.md for the pattern.

## Usage

Run the CLI from inside the app repository (or set `SIMTUNNEL_REPO=<owner>/<repo>`).

```bash
simtunnel up <session> --wait          # dispatch and block until WebDriverAgent answers
simtunnel status <session>             # GET /status
simtunnel screenshot <session> out.jpg # one frame from the MJPEG stream (fast even over DERP relay)
simtunnel record <session> out.mjpeg --duration 30 --mp4
simtunnel preview <session>            # browser UI with live video and click-to-tap
simtunnel list
simtunnel down <session>
```

Talk to WebDriverAgent directly:

```bash
curl -s http://simtunnel-<session>:8100/status
curl -s http://simtunnel-<session>:8100/source/?format=json
```

Things WebDriverAgent cannot do go through the agentd allow list:

```bash
curl -s -X POST http://simtunnel-<session>:8200/v1/relaunch \
  -H 'Content-Type: application/json' -d '{"slot": 0, "args": ["-UITEST", "1"]}'
curl -s -X POST http://simtunnel-<session>:8200/v1/push \
  -H 'Content-Type: application/json' -d '{"payload": {"aps": {"alert": "hello"}}}'
curl -s -X POST http://simtunnel-<session>:8200/v1/status_bar \
  -H 'Content-Type: application/json' -d '{"time": "09:41", "batteryLevel": 100}'
```

### MCP server

`mcp/index.mjs` exposes WebDriverAgent as MCP tools (`status`, `screenshot`, `tap`, `swipe`, `type_text`, `press_button`, `source`, `open_url`) plus mobile-mcp compatible tool names so existing skills keep working.

```bash
(cd mcp && npm install)
simtunnel mcp-config <session> <worktree dir>            # writes .mcp.json for Claude Code
simtunnel mcp-config <session> <worktree dir> --name mobile  # register as "mobile" for mobile-mcp compatible skills
```

Codex reads the same server from `~/.codex/config.toml` with `SIMTUNNEL_WDA_URL=http://simtunnel-<session>:8100`.

### Multiple simulators per runner

`up --simulators N` boots N simulators on one runner (clones of the device). Simulator `i` listens on `8100+i` / `9100+i`. Address it with `--slot <i>`. Runner memory is small, so 2 to 3 is the practical ceiling.

### Onboarding flows with Maestro

If the app repository has `.maestro/flows/simtunnel/setup.yml`, the runner executes it after the app launches and before WebDriverAgent starts. Use it to click through onboarding once per session instead of tapping through it with the agent.

### macOS apps

`macos-session.yml` does the same for macOS apps using WebDriverAgentMac in the runner's GUI session. Screenshots come from `GET /screenshot` (there is no MJPEG stream on macOS). One desktop per runner, so parallelism comes from more runners.

## Security design

WebDriverAgent has no authentication. Reaching it means fully controlling the simulator, so the only safe design is to never expose it.

- Zero public endpoints. Everything is reachable only inside your tailnet. No Cloudflare Tunnel, no ngrok.
- `workflow_dispatch` only. Fork pull requests never receive secrets or OIDC tokens.
- No long-lived secrets. Tailscale auth uses GitHub's short-lived OIDC token.
- `tag:ci` cannot initiate connections to anything in the tailnet.
- Ephemeral nodes. Runners leave the tailnet when the job ends.
- agentd accepts fixed verbs with schema-validated arguments. It never runs a command string, script, or file path sent by a client.
- Third-party actions are pinned to full commit SHAs. Runner scripts are checked out at the same SHA as the reusable workflow.

## Limits and GitHub's terms

| | |
|---|---|
| Job duration | 6 hours max per job |
| Concurrent macOS jobs | 5 on Free / Pro / Team plans |
| Larger runners | always billed, even on public repositories |

GitHub's [Terms for Additional Products and Features](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features) restrict GitHub-hosted runners to the production, testing, deployment, or publication of the software project associated with the repository where the workflow runs. That is why simtunnel is a reusable workflow: run it from the repository of the app you are testing, not from this repository. Shut sessions down when you are done.

## Repository layout

```text
.github/workflows/session.yml        reusable workflow: iOS simulator session
.github/workflows/macos-session.yml  reusable workflow: macOS app session
.github/workflows/*-session.yml      workflow_dispatch wrappers used by this repository itself
runner/                              scripts executed on the runner (boot, build, WDA, agentd, keepalive)
local/simtunnel                      local CLI
mcp/                                 MCP server
iOSProject/ macOSProject/            sample apps used for this repository's own verification
PROJECT.md                           design decisions, measurements, and setup details (Japanese)
```

## License

[MIT](LICENSE)
