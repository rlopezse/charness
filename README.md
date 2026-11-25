# Charness

A small local GUI for Claude, laid out like T3 Code (projects → threads → chat, with approvals, a
git "Changes" panel and a mode/model picker) but **Claude only** and built so you can read all of it.
While Claude works, a live status line shows what it is doing right now (thinking, writing, the command
it is running and for how long, waiting for your approval) above a short log of this turn's steps,
including the ones sub-agents take. That feed is live only; it is not saved with the thread.
The 📎 button attaches files of any kind (up to 10 per message, 25 MB each). They are stored per thread in
`~/.charness/uploads/<thread>/` (not in your project), Claude gets read access to that folder and their paths,
and they are deleted with the thread. They are never served back to the browser.

It runs the Claude Code binary (closed-source; the one the official Claude Agent SDK ships) as a child
process and talks to it over its stream-json protocol from a small Swift server, with no other code in
between. This repo adds a UI and a lot of locks around that process.

## Run it

Needs Swift 5.9+ (macOS: the Command Line Tools, `xcode-select --install`; Linux: a swift.org toolchain) and
Node 20+ (only to download the Claude Code binary and to run the end-to-end test).

```bash
npm install          # downloads the Claude Code binary (@anthropic-ai/claude-agent-sdk, pinned)
export ANTHROPIC_API_KEY=sk-ant-...      # or be logged in to Claude Code already (see "Auth")
npm start            # builds and runs the Swift server; prints  http://127.0.0.1:4317/?token=...  — open it once
```

Try it without any model or key: `npm run mock`. Run the checks: `npm test` (end to end) and `npm run check`
(the Swift self-test). On a Mac, the app below is the easier way.

Add a project folder in the sidebar (type its path), press **+** for a thread, and chat.

## What it does for privacy

| Risk | What this does |
|---|---|
| Claude Code telemetry / error reports / update checks | Forced off for the child process: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`, `DO_NOT_TRACK`, feedback survey off. No `OTEL_*` is passed. |
| Unknown outbound connections | **Egress guard**: Claude's process is started with `HTTPS_PROXY` pointing at a tiny proxy inside this server. Only `api.anthropic.com:443` is tunnelled (plus anything you allow). Every attempt, allowed or blocked, is listed in the **Network** panel. The guard sees host and port only, never contents. |
| Your other secrets leaking into the agent | The child gets an allow-listed environment (PATH, HOME, locale, proxy/CA vars, and the Anthropic auth vars). `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK` etc. are **not** passed. Add what you need with `HARNESS_PASS_ENV=A,B`. |
| Other web pages talking to your local server | Loopback only; random 256-bit token → `HttpOnly; SameSite=Strict` cookie; `Host` and `Origin` checks on every request (blocks DNS-rebinding and cross-site POSTs); strict CSP (`default-src 'none'`, scripts/styles/connect `'self'`). |
| A cloned repo changing Claude's behaviour | Project `CLAUDE.md` / `.claude/settings.json` (hooks, env…) are **always loaded** for every project, so only add folders you trust. Your user-level `~/.claude` settings and hooks are not loaded. |
| Accidents | Default mode asks before edits/commands. "Auto-accept edits & commands" is opt-in per thread: Charness approves shell commands itself (other tools still ask, the egress guard still applies), so only use it in projects you're happy for Claude to run anything in. "Full access (no prompts)" does not exist unless you start with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled so every question is a normal chat message. |
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

Double-click the app: the Charness server runs inside it and the UI opens in its own native window.
**Cmd-Q (or Dock → Quit) stops it.** Closing the window keeps it running; clicking the Dock icon brings the same
window back. The app points at this folder, so keep it where it is (re-run the script if you move it). It uses
the same data as `npm start` (`~/.charness`); don't run both at the same time.

* **API key:** apps don't see what you `export` in Terminal. Store the key once in the Keychain instead
  (it asks you to type it; macOS may ask "Always Allow" the first time the app reads it):
  `security add-generic-password -a "$USER" -s charness -w`
  Or skip this if you're already logged in to Claude Code on the Mac.
* **Window:** the app is a small native Swift program (`mac/Sources/Charness`, AppKit + SwiftUI, no third-party
  code) with native screens: the same sidebar, chat, approvals, attachments and Changes/Network panels as the web
  UI. They talk to the in-app server over loopback exactly like the web UI does (token, cookie, every check).
  ⌘N new thread, ⌘O add a project folder, ⌥⌘1 / ⌥⌘2 Changes / Network, ⌘R reload. Links in chats open in your
  default browser. No browser is launched, so no extensions can read your chats and no extra tabs pile up.
* **Web interface fallback:** View ▸ Use Web Interface shows `public/` in the window instead (WKWebView, as
  before; ⌘= / ⌘- / ⌘0 zoom there). The choice is remembered. Web Inspector, if you need it:
  `defaults write local.charness.app CharnessInspectable -bool true`.
* **PATH:** apps opened from Finder get a bare PATH, so at launch the app asks your login shell for its PATH
  (`$SHELL -i -l -c`, given up after 5 s) and hands that to Claude Code: its commands find Homebrew, nvm…
  tools as in Terminal. Only PATH is taken from the shell. Off with
  `defaults write local.charness.app CharnessShellPath -bool false`.
* The built-in Mac permission prompts (Documents, Desktop…) appear for folders you add as projects. That's macOS.
* **Tools** (Command Line Tools are enough, no Xcode): `swift run --package-path mac charness-check` checks your
  real `~/.charness` against the store (read-only: it never changes a file or prints chat contents);
  `swift run --package-path mac claude-spike "your prompt"` runs one turn with the real Claude Code in the
  terminal, asking approvals there (Ctrl-C stops it; no egress guard; `--mock` for the mock).
* The server, the HTTP layer, the guard and all checks build and run on Linux too; the app itself (AppKit, the
  Keychain, `codesign`) only on a Mac.

## History

Until November 2026 the server was Node (`server.mjs`, `lib/*.mjs`, driving Claude Code through the Agent SDK).
It was ported to Swift step by step and checked against the Node version all along (same replies, live events
and files on disk); see `SWIFT_PORT_PLAN.md`. The Node code is in git history. What the Node version did is kept
as expected results in `mac/Fixtures` (recorded turns, guard answers, the environment allow-list).

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

Models in the dropdown are listed in `mac/Sources/CharnessCore/Server.swift` (`models`); "Default" lets Claude
Code choose. `npm start -- --port 4400` (or `swift run --package-path mac charness-server --port 4400`) passes flags.

## Layout

```
public/           the web UI: index.html, app.js, md.js, reduce.js, style.css (no framework, no build)
mac/              Swift package (no third-party packages)
  Sources/CharnessCore   everything but the window, Foundation only (macOS and Linux):
                           Server.swift + HTTP.swift   HTTP + SSE server, auth, routes
                           ClaudeProcess.swift         runs claude over stream-json, permission prompts
                           Turn.swift                  one turn: UI events, live activity, env allow-list
                           Mock.swift                  the mock backend (npm run mock)
                           Reducer.swift               twin of public/reduce.js (saving threads)
                           Guard.swift                 egress guard (CONNECT proxy)
                           Store.swift + JSON.swift    JSON persistence, byte-compatible with JavaScript
                           Uploads.swift               attached files
                           Client.swift                the native screens' API client, live feed and state
                           Markdown.swift              port of public/md.js for the native screens
                           ShellPath.swift             the login shell's PATH, for the app
  Sources/Charness       the macOS app: the server in-process + native SwiftUI screens (web UI as fallback)
  Sources/charness-server the server in a terminal (npm start)
  Sources/core-checks    self-test (npm run check); expected results in mac/Fixtures
  Sources/charness-check read-only check of your data
  Sources/claude-spike   one real turn in the terminal
scripts/          make-mac-app.sh (builds Charness.app)
test/smoke.mjs    31 end-to-end checks against the server in mock mode (npm test)
```
