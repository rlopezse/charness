# Charness

A small native Mac app for Claude, laid out like T3 Code (projects → threads → chat, with approvals, a
git "Changes" panel and a mode/model picker) but **Claude only** and built so you can read all of it.
While Claude works, a live status line shows what it is doing right now (thinking, writing, the command
it is running and for how long, waiting for your approval) above a short log of this turn's steps,
including the ones sub-agents take. That feed is live only; it is not saved with the thread.
The 📎 button (or dropping files on the conversation) attaches files of any kind (up to 10 per message, 25 MB
each). They are stored per thread in `~/.charness/uploads/<thread>/` (not in your project), Claude gets read
access to that folder and their paths, and they are deleted with the thread.

It runs the Claude Code binary (closed-source; the build the official Claude Agent SDK ships) as a child
process and talks to it over its stream-json protocol from a small Swift server inside the app, with no other
code in between. This repo adds the app and a lot of locks around that process. It is all Swift: no Node, no
web pages, no third-party packages.

## Build it

On a Mac with macOS 14 or later:

```bash
xcode-select --install             # once, if you don't have the Command Line Tools (for Swift)
./scripts/make-mac-app.sh          # builds  ~/Applications/Charness.app
```

The first build downloads Claude Code (about 170 MB) from the npm registry and refuses it unless its checksum
matches the one pinned in the script; later builds reuse that copy. The app is self-contained (about 400 MB,
almost all of it Claude Code): once built it doesn't need this folder, so you can move it or copy it to another
Mac with the same kind of chip.

Open it, add a project folder (**Add Project** in the sidebar, ⌘O, or drop a folder on the sidebar), start a
thread and chat. **Cmd-Q (or Dock → Quit) stops it.** Closing the window keeps it running; clicking the Dock
icon brings the same window back. ⌘N new thread, ⌥⌘1 / ⌥⌘2 Changes / Network, ⌘R reload. Links in chats open
in your default browser.

Try it without any model or key (a built-in mock Claude): `open -a Charness --args --mock`.

## Auth

* **API key:** apps don't see what you `export` in Terminal. Store the key once in the Keychain instead
  (it asks you to type it; macOS may ask "Always Allow" the first time the app reads it):
  `security add-generic-password -a "$USER" -s charness -w`
  It is passed to Claude Code and nothing else.
* Or log in once with Claude Code itself (`claude auth login`); the credentials it stores are picked up.

## What it does for privacy

| Risk | What this does |
|---|---|
| Claude Code telemetry / error reports / update checks | Forced off for the child process: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`, `DO_NOT_TRACK`, feedback survey off. No `OTEL_*` is passed. |
| Unknown outbound connections | **Egress guard**: Claude's process is started with `HTTPS_PROXY` pointing at a tiny proxy inside the app. Only `api.anthropic.com:443` is tunnelled (plus anything you allow). Every attempt, allowed or blocked, is listed in the **Network** panel. The guard sees host and port only, never contents. |
| Your other secrets leaking into the agent | The child gets an allow-listed environment (PATH, HOME, locale, proxy/CA vars, and the Anthropic auth vars). `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK` etc. are **not** passed. Add what you need with `HARNESS_PASS_ENV=A,B`. |
| Other programs or web pages driving the app | The app's server listens on loopback only and accepts only the app itself: a random 256-bit token → `HttpOnly; SameSite=Strict` cookie, `Host` and `Origin` checks and an `X-Harness` header on every change (blocks DNS rebinding and cross-site requests). It serves no web pages. |
| A cloned repo changing Claude's behaviour | Project `CLAUDE.md` / `.claude/settings.json` (hooks, env…) are **always loaded** for every project, so only add folders you trust. Your user-level `~/.claude` settings and hooks are not loaded. |
| Accidents | Default mode asks before edits/commands. "Auto-accept edits & commands" is opt-in per thread: Charness approves shell commands itself (other tools still ask, the egress guard still applies), so only use it in projects you're happy for Claude to run anything in. "Full access (no prompts)" does not exist unless the app is started with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled so every question is a normal chat message. |
| Third-party code | None: no packages, no frameworks beyond Apple's, no analytics. The git panel runs read-only git with `fsmonitor` and external diff/textconv disabled. |
| A tampered Claude Code download | The build pins Claude Code's SHA-512 and refuses anything else. |
| Data at rest | `~/.charness` (dirs `0700`, files `0600`): projects, threads, access token. Delete a thread/project in the app and its file is removed. |

## What it cannot promise (please read)

* **The Claude Code binary is closed-source.** It ships as a compiled executable; I could not audit it.
  Everything above limits and *watches* it, but the proof is observation: open **Network** after a few messages.
  In my test run (a short turn with a deliberately invalid key) the only host contacted was `api.anthropic.com`.
* **Proxy variables are advisory.** A process that ignores `HTTPS_PROXY` would bypass the guard. For a hard
  guarantee, also use a firewall that only allows `api.anthropic.com` for it (e.g. Little Snitch or LuLu).
* **Your prompts and the files Claude reads go to Anthropic.** That is the product working, not a leak.
* **Commands you approve run as you**, in the project folder. Approve carefully; use a throwaway folder for risky work.
* **Claude Code also keeps its own session transcripts** under `~/.claude/` (needed to resume threads).
* Bash/WebFetch run by the agent also inherit the guard, so `npm install`, `git fetch` etc. will be blocked
  until you press **Allow** on that host in the Network panel.
* I could not test a subscription (OAuth) login in my build environment. If you use one, token refresh may
  show a blocked host in Network — Allow it if you recognise it.

## Settings

The app's own preferences (`defaults write local.charness.app KEY …`, then reopen the app):

| | |
|---|---|
| `CharnessMock -bool true` | always start with the mock Claude (or once: `open -a Charness --args --mock`) |
| `CharnessShellPath -bool false` | don't take PATH from your login shell (by default the app asks `$SHELL -i -l -c`, given up after 5 s, so Claude's commands find Homebrew, nvm… as in Terminal; only PATH is taken) |

Environment variables are read when the app starts. Apps opened from Finder don't get your shell's, so to use
one, start the app from Terminal: `HARNESS_ALLOW_HOSTS=pypi.org ~/Applications/Charness.app/Contents/MacOS/Charness`.

| | |
|---|---|
| `HARNESS_ALLOW_HOSTS=a.com,b.com:8443` | extra allowed hosts (or press **Allow** in the Network panel) |
| `HARNESS_UPSTREAM_PROXY` | corporate proxy to chain through (defaults to your `HTTPS_PROXY`) |
| `HARNESS_PASS_ENV=A,B` | extra env vars the Claude process may see |
| `HARNESS_ALLOW_FULL_ACCESS=1` | adds the no-prompt mode |
| `HARNESS_NET_GUARD=off` | disable the egress guard (not recommended) |
| `HARNESS_CLAUDE_BIN=/path/to/claude` | run another Claude Code than the one inside the app (also: build the app with it) |
| `HARNESS_HOME` | data dir (default `~/.charness`) |
| `PORT` | first port the in-app server tries (default 4317, then the next free one) |

Models in the menu are listed in `mac/Sources/CharnessCore/Server.swift` (`models`); "Default" lets Claude
Code choose.

## Updating Claude Code

The version and its checksums are pinned at the top of `scripts/make-mac-app.sh`. To move to a newer one,
pick the version of `@anthropic-ai/claude-agent-sdk` you want, read the two checksums the npm registry
publishes for it, put all three in the script, rebuild the app, and try a turn (and `claude-spike`, below):

```bash
V=0.3.400   # for example
for a in arm64 x64; do
  curl -s "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk-darwin-$a/$V" | plutil -extract dist.integrity raw -
done
```

## Developing

* **Checks:** `swift run --package-path mac core-checks` (also on Linux; the Command Line Tools are enough, no
  Xcode). 128 checks: the store, the reducer, the egress guard, Claude Code turns against a strict stand-in
  (the checks program plays it itself), the app's client, Markdown, and the server end to end in mock mode.
  The SwiftUI screens themselves are only built and tried on a Mac.
* **Xcode, for quick UI changes:** `open mac/Package.swift`, pick the **Charness Mock** scheme and ⌘R. It runs
  the app with the mock Claude (no key, no cost) and its own throwaway data in `/tmp/charness-dev`, next to your
  installed Charness. Edit a view, ⌘R again. (The plain **Charness** scheme uses your real data and needs
  `HARNESS_CLAUDE_BIN` pointing at a Claude Code, e.g. `mac/.build/claude-code/claude` after one app build.)
* **The real Claude Code in a terminal:** `swift run --package-path mac claude-spike "your prompt"` runs one turn,
  asking approvals there (Ctrl-C stops it; no egress guard; `--mock` for the mock).
* Everything but the window builds and runs on Linux too; the app itself (AppKit, SwiftUI, the Keychain,
  `codesign`) only on a Mac.

## History

Until November 2026 the server was Node (`server.mjs`, `lib/*.mjs`, driving Claude Code through the Agent SDK)
with a web UI (`public/`). It was ported to Swift step by step and checked against the Node version all along
(same replies, live events and files on disk), then the web UI was replaced by native screens and both were
retired; see `SWIFT_PORT_PLAN.md`. They are in git history. What they did is kept as expected results in
`mac/Fixtures` (recorded turns, guard answers, the environment allow-list, the reducer, Markdown).

## Layout

```
mac/              Swift package (no third-party packages)
  Sources/CharnessCore   everything but the window, Foundation only (macOS and Linux):
                           Server.swift + HTTP.swift   the in-app loopback server: auth, routes, live events
                           ClaudeProcess.swift         runs claude over stream-json, permission prompts
                           Turn.swift                  one turn: UI events, live activity, env allow-list
                           Mock.swift                  the mock Claude (--mock)
                           Reducer.swift               folds events into saved threads
                           Guard.swift                 egress guard (CONNECT proxy)
                           Store.swift + JSON.swift    JSON persistence, byte-compatible with the Node version
                           Uploads.swift               attached files
                           Client.swift                the screens' API client, live feed and state
                           Markdown.swift              Markdown for the screens
                           ShellPath.swift             the login shell's PATH
  Sources/Charness       the macOS app: the server in-process + SwiftUI screens
  Sources/core-checks    self-test (and the Claude Code stand-in); expected results in mac/Fixtures
  Sources/claude-spike   one real turn in the terminal
  Resources/AppIcon.png  the app icon (the build makes the .icns from it)
scripts/          make-mac-app.sh (downloads and checks Claude Code, builds Charness.app)
```
