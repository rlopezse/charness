# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
./scripts/make-mac-app.sh                              # builds ~/Applications/Charness.app (downloads + checks Claude Code once)
swift run --package-path mac core-checks               # the self-test (also runs on Linux; no Xcode needed)
swift run --package-path mac claude-spike "prompt"     # one real Claude Code turn in the terminal, approvals there
open -a Charness --args --mock                         # the app with the mock Claude: no network / API key needed
```

There is no linter and no test framework: `core-checks` is one program (so a single check can't run in isolation). It covers the store, the reducer, the egress guard, Claude Code turns against a strict stand-in that the same program plays (`core-checks --fake-claude`, `FakeClaude.swift`), the app's client, Markdown, and the server end to end in mock mode on a random port with a temp `HARNESS_HOME`. The SwiftUI views are not covered: they only build on a Mac. Settings (preferences and env vars such as `HARNESS_ALLOW_HOSTS`, `HARNESS_PASS_ENV`, `HARNESS_ALLOW_FULL_ACCESS`, `HARNESS_HOME`) are tabulated in `README.md`.

## Architecture

A native macOS app (projects → threads → chat) over the closed-source Claude Code binary, which a small Swift server inside the app runs as a child process and drives over its stream-json protocol. All Swift: no Node, no web pages, no frameworks beyond Apple's and no third-party packages; the point is that all of it stays readable and auditable. Keep it that way.

- `mac/Sources/CharnessCore/` — Foundation-only, builds on macOS and Linux (so everything but drawing is tested on Linux):
  - `Server.swift` + `HTTP.swift` — the in-app loopback HTTP/1.1 + SSE server: token auth (token → `HttpOnly; SameSite=Strict` cookie), `Host`/`Origin`/`X-Harness` checks, security headers, REST routes under `/api/*` (no web pages), the `models` list, runs and permission prompts, the read-only git panel.
  - `ClaudeProcess.swift` — starts `claude` with the flags/env the Agent SDK used, speaks stream-json, answers `can_use_tool` permission prompts. `Turn.swift` turns its messages into UI events and the live activity feed, and builds the child's environment from an allow-list (`AgentEnvironment`). `Mock.swift` is the mock Claude.
  - `Guard.swift` — egress guard: a small CONNECT proxy the child is pointed at via `HTTPS_PROXY`; only `api.anthropic.com:443` plus user-allowed hosts are tunnelled, every attempt is logged to the Network panel.
  - `Store.swift` + `JSON.swift` — JSON persistence under `HARNESS_HOME` (default `~/.charness`, dirs 0700 / files 0600). `JSON.swift` mirrors `JSON.parse`/`JSON.stringify` exactly (key order, number formatting) so files stay byte-compatible with what the Node version wrote. `Reducer.swift` folds agent events into the saved message list.
  - `Uploads.swift` — attached files: `POST /api/threads/:id/files` (raw bytes, name in `X-File-Name`) stores them in `HARNESS_HOME/uploads/<threadId>/` (0700/0600, cleaned names); `/send` takes `files: [names]`, lists their paths in the prompt and gives Claude the folder (`--add-dir`). Paths are built as strings, not `URL`, so macOS doesn't decompose Unicode names.
  - `Client.swift` — what the screens run on: `APIClient` (loopback HTTP with the token → cookie, `Origin` and `X-Harness`, so every server check applies), `EventStream` (the `/api/events` feed, reconnecting) and `ClientState` (the screen state; folds live events with `Reducer.apply`). `Markdown.swift` gives blocks and inline runs. `ShellPath.swift` reads the login shell's PATH for the app.
- `mac/Sources/Charness/` — the macOS app: runs `CharnessServer` in-process and shows SwiftUI screens (`AppModel.swift` drives `Client.swift`; `Screens.swift`, `MessageViews.swift` only draw). Claude Code is taken from inside the bundle (`Contents/MacOS/claude`). File pickers via `NSOpenPanel`, API key from the Keychain item "charness", PATH from the login shell, `--mock` / `CharnessMock` for the mock. SwiftUI can't be compiled on Linux: keep logic in `CharnessCore` and the views thin.
- `scripts/make-mac-app.sh` — downloads Claude Code from the npm registry with curl, refuses it unless its SHA-512 matches the pinned one, caches it in `mac/.build/claude-code/`, and builds a self-contained `Charness.app` with it and the icon (`mac/Resources/AppIcon.png`).
- `mac/Fixtures/` — expected results for `core-checks`, recorded from the retired Node version and web UI (`turns/*.json`: what the real Agent SDK reported for the strict stand-in; `guard.json`; `env.json`; `node-home/`; `reducer.json`; `markdown.json`; `js-format.tsv`). They can no longer be regenerated: new behaviour gets new checks written by hand. If Claude Code's protocol changes, `claude-spike` against the real binary is the check, and the recordings are updated by hand.

The server used to be Node (`server.mjs`, `lib/*.mjs`) with a web UI (`public/`); see `SWIFT_PORT_PLAN.md` and git history.

Security posture is the product; preserve these invariants when changing code:
- The child process gets only an allow-listed env (no `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`...), telemetry/update checks forced off, and project/user `CLAUDE.md` and settings are not loaded unless the project opts in.
- Default permission mode asks before edits/commands. "Auto-accept edits & commands" (`commands`, opt-in per thread) is `acceptEdits` plus the server answering `Bash`/`BashOutput`/`KillShell` prompts itself (`Mode.autoAllow`, read from the thread's current mode at each prompt); every other tool still asks. The no-prompt mode exists only with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled.
- The in-app server stays loopback-only and accepts only the app: token → cookie, `Host` check on every request, `Origin` + `X-Harness` on every change. It serves no web pages.
- Claude Code is pinned by checksum in `scripts/make-mac-app.sh`; never bundle an unchecked download.
- The git "Changes" panel runs read-only git with `fsmonitor` and external diff/textconv disabled.

Adding behavior usually means touching a route in `mac/Sources/CharnessCore/Server.swift`, the matching client code (`Client.swift`) and screens (`mac/Sources/Charness/`), and a check in `core-checks` (mock mode; the real Claude Code path is not covered by tests — use `claude-spike`), then running `core-checks`. Rebuild the app (`./scripts/make-mac-app.sh`) to use the change.

## Working rules

- Never suggest or offer to delete branches (local or remote). Only delete one if the user explicitly asks.
- When the user says "reboot server" (or "restart the server"): the server runs inside Charness.app, so quit the app and open it again (rebuild it first with `./scripts/make-mac-app.sh` if the code changed). Don't ask first.
