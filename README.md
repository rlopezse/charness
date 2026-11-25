# Charness

A small local GUI for Claude, laid out like T3 Code (projects → threads → chat, with approvals, a
git "Changes" panel and a mode/model picker) but **Claude only** and built so you can read all of it.
While Claude works, a live status line shows what it is doing right now (thinking, writing, the command
it is running and for how long, waiting for your approval) above a short log of this turn's steps,
including the ones sub-agents take. That feed is live only; it is not saved with the thread.
The 📎 button attaches files of any kind (up to 10 per message, 25 MB each). They are stored per thread in
`~/.charness/uploads/<thread>/` (not in your project), Claude gets read access to that folder and their paths,
and they are deleted with the thread. They are never served back to the browser.

It drives Claude through the official Claude Agent SDK, which runs the Claude Code binary as a child
process. This repo adds a UI and a lot of locks around that process.

## Run it

```bash
npm install          # Node 20+. One dependency: @anthropic-ai/claude-agent-sdk (pinned)
export ANTHROPIC_API_KEY=sk-ant-...      # or be logged in to Claude Code already (see "Auth")
npm start            # prints  http://127.0.0.1:4317/?token=...  — open that link once
```

Try it without any model or key: `npm run mock`. Run the checks: `npm test`.

Add a project folder in the sidebar (type its path), press **+** for a thread, and chat.

## What it does for privacy

| Risk | What this does |
|---|---|
| Claude Code telemetry / error reports / update checks | Forced off for the child process: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`, `DO_NOT_TRACK`, feedback survey off. No `OTEL_*` is passed. |
| Unknown outbound connections | **Egress guard**: Claude's process is started with `HTTPS_PROXY` pointing at a tiny proxy inside this server. Only `api.anthropic.com:443` is tunnelled (plus anything you allow). Every attempt, allowed or blocked, is listed in the **Network** panel. The guard sees host and port only, never contents. |
| Your other secrets leaking into the agent | The child gets an allow-listed environment (PATH, HOME, locale, proxy/CA vars, and the Anthropic auth vars). `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK` etc. are **not** passed. Add what you need with `HARNESS_PASS_ENV=A,B`. |
| Other web pages talking to your local server | Loopback only; random 256-bit token → `HttpOnly; SameSite=Strict` cookie; `Host` and `Origin` checks on every request (blocks DNS-rebinding and cross-site POSTs); strict CSP (`default-src 'none'`, scripts/styles/connect `'self'`). |
| A cloned repo changing Claude's behaviour | Project `CLAUDE.md` / `.claude/settings.json` (hooks, env…) are **always loaded** for every project, so only add folders you trust. Your user-level `~/.claude` settings and hooks are not loaded. |
| Accidents | Default mode asks before edits/commands. "Full access (no prompts)" does not exist unless you start with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled so every question is a normal chat message. |
| Third-party code in the UI | None: no framework, no CDN, no fonts, no analytics. Markdown is rendered with DOM nodes (never `innerHTML`). The git panel runs read-only git with `fsmonitor` and external diff/textconv disabled. |
| Data at rest | `~/.charness` (dirs `0700`, files `0600`): projects, threads, access token. Delete a thread/project in the UI and its file is removed. |

## What it cannot promise (please read)

* **The Claude Code binary is closed-source.** The SDK ships it as a compiled executable; I could not audit it.
  Everything above limits and *watches* it, but the proof is observation: open **Network** after a few messages.
  In my test run (a short turn with a deliberately invalid key) the only host contacted was `api.anthropic.com`.
* **Proxy variables are advisory.** A process that ignores `HTTPS_PROXY` would bypass the guard. For a hard
  guarantee, also run this in a container/VM or behind a firewall that only allows `api.anthropic.com`
  (e.g. `docker run --network` with an egress rule, or an `iptables`/Little Snitch/OpenSnitch rule).
* **Your prompts and the files Claude reads go to Anthropic.** That is the product working, not a leak.
* **Commands you approve run as you**, in the project folder. Approve carefully; use a throwaway folder for risky work.
* **Claude Code also keeps its own session transcripts** under `~/.claude/` (needed to resume threads).
* Bash/WebFetch run by the agent also inherit the guard, so `npm install`, `git fetch` etc. will be blocked
  until you press **Allow** on that host in the Network panel.
* I could not test a subscription (OAuth) login in my build environment. If you use one, token refresh may
  show a blocked host in Network — Allow it if you recognise it.

## Auth

* API key: `export ANTHROPIC_API_KEY=...` before `npm start` (it is passed to Claude and nothing else).
* Or log in once with the Claude Code CLI (`claude auth login`); the credentials it stores are picked up.
  If your installed CLI is the one you trust, point at it with `HARNESS_CLAUDE_BIN=/path/to/claude`.

## Run it as a Mac app

```bash
xcode-select --install             # once, if you don't have the Command Line Tools (for Swift)
npm install                        # once: downloads the Claude Code binary the app runs
./scripts/make-mac-app.sh          # builds  ~/Applications/Charness.app
```

Double-click the app: the Charness server runs inside it (Swift; no Node at run time) and the UI opens in its own
native window. **Cmd-Q (or Dock → Quit) stops it.** Closing the window keeps it running; clicking the Dock icon
brings the same window back. The app points at this folder, so keep it where it is (re-run the script if you
move it). It uses the same data as `npm start` (`~/.charness`), so you can switch between them; on launch it stops
a Node server the previous version of the app may have left running.

* **API key:** apps don't see what you `export` in Terminal. Store the key once in the Keychain instead
  (it asks you to type it; macOS may ask "Always Allow" the first time the app reads it):
  `security add-generic-password -a "$USER" -s charness -w`
  Or skip this if you're already logged in to Claude Code on the Mac.
* **Window:** the app is a small native Swift program (`mac/Sources/Charness`, AppKit + WKWebView, no third-party code).
  It shows only this server; links in chats open in your default browser. No browser is launched, so no
  extensions can read your chats and no extra tabs or windows pile up. Edit menu, ⌘R reload and ⌘= / ⌘- / ⌘0 zoom work.
  Web Inspector, if you need it: `defaults write local.charness.app CharnessInspectable -bool true`.
* The built-in Mac permission prompts (Documents, Desktop…) appear for folders you add as projects. That's macOS.
* **Swift checks** (Command Line Tools are enough, no Xcode): `swift run --package-path mac core-checks` tests the
  Swift port; `swift run --package-path mac charness-check` compares your real `~/.charness` with what the Swift
  store would write. It only reads: it never changes a file and never prints chat contents.
  `swift run --package-path mac claude-spike "your prompt"` runs one turn with the real Claude Code straight from
  Swift (no Node, no Agent SDK), asking approvals in the terminal; Ctrl-C stops it. It skips the egress guard.
  Add `--mock` to use the built-in mock instead of Claude (like `npm run mock`).
* **The Swift server** (`mac/Sources/CharnessCore/Server.swift`) is a port of `server.mjs`; `npm run test:swift`
  runs `test/smoke.mjs` against it and `test/compare-servers.mjs`, which replays one session on both servers and
  requires the same replies, live events and files on disk. `swift run --package-path mac charness-server` runs it
  in the terminal with the same flags as `node server.mjs`.
* The Swift server, the HTTP layer, the guard and all checks were built and run on Linux by me; the app itself
  (AppKit, the Keychain, `codesign`) only builds and runs on a Mac.

## Settings (environment variables / flags)

| | |
|---|---|
| `--port N` / `PORT` | default 4317 |
| `--open` | open the browser at start |
| `--rotate-token` | make a new access token (old links stop working) |
| `--mock` | fake backend, no network |
| `--no-guard` / `HARNESS_NET_GUARD=off` | disable the egress guard (not recommended) |
| `HARNESS_ALLOW_HOSTS=a.com,b.com:8443` | extra allowed hosts |
| `HARNESS_UPSTREAM_PROXY` | corporate proxy to chain through (defaults to your `HTTPS_PROXY`) |
| `HARNESS_PASS_ENV=A,B` | extra env vars the Claude process may see |
| `HARNESS_ALLOW_FULL_ACCESS=1` | adds the no-prompt mode |
| `HARNESS_HOME` | data dir (default `~/.charness`) |

Models in the dropdown are listed in `server.mjs` (`MODELS`); "Default" lets Claude Code choose.

## Layout

```
server.mjs        HTTP + SSE server, auth, routes            (~430)
lib/agent.mjs     Agent SDK bridge, env allow-list, mock     (~200)
lib/guard.mjs     egress guard (CONNECT proxy)               (~95)
lib/store.mjs     JSON persistence                           (~70)
lib/uploads.mjs   attached files (per-thread folder, safe names)
public/           index.html, app.js, md.js, reduce.js, style.css
mac/              Swift package (see mac/Package.swift and SWIFT_PORT_PLAN.md); Charness.app runs its server
  Sources/Charness       native macOS window (AppKit + WKWebView)
  Sources/CharnessCore   Foundation-only ports of the Node code: JSON.swift, Store.swift (lib/store.mjs),
                         ClaudeProcess.swift + Turn.swift (lib/agent.mjs: talks to Claude Code directly),
                         Mock.swift (the mock backend), Reducer.swift (public/reduce.js),
                         Guard.swift (lib/guard.mjs), Uploads.swift (lib/uploads.mjs),
                         HTTP.swift + Server.swift (server.mjs)
  Sources/charness-server the Swift server as a terminal program (same flags as server.mjs)
  Sources/claude-spike   one turn with the real Claude Code from Swift, in the terminal
  Sources/core-checks    self-test (fixtures in mac/Fixtures are real Node output)
  Sources/charness-check read-only check of your data against the Swift store
scripts/          launch.sh (start/stop for the app), make-mac-app.sh (builds mac/ into Charness.app)
test/smoke.mjs    29 end-to-end checks in mock mode (CHARNESS_SERVER=... runs them on the Swift server)
test/compare-servers.mjs  same session on the Node and Swift servers; replies, events and files must match
```
