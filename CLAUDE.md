# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm install                 # downloads the Claude Code binary (@anthropic-ai/claude-agent-sdk, pinned); Node >= 20
npm start                   # builds + runs the Swift server; prints http://127.0.0.1:4317/?token=... (open that link once)
npm run mock                # same, with the mock backend: no network / API key needed
npm test                    # builds the server, then node test/smoke.mjs: end-to-end checks against it in mock mode
npm run check               # swift run --package-path mac core-checks: Swift self-test (also runs on Linux; no Xcode needed)
./scripts/make-mac-app.sh   # builds ~/Applications/Charness.app
swift run --package-path mac charness-check  # read-only check of ~/.charness against the store
swift run --package-path mac claude-spike "prompt"   # one real Claude Code turn in the terminal, approvals there
```

There is no linter. `test/smoke.mjs` is one script that spawns the server (`mac/.build/debug/charness-server`, or `CHARNESS_SERVER=`) in mock mode on a random port with a temp `HARNESS_HOME` and asserts on it, so it can't run a single test in isolation; `core-checks` is likewise one program. Server flags/env vars (`--port`, `--rotate-token`, `--no-guard`, `HARNESS_ALLOW_HOSTS`, `HARNESS_PASS_ENV`, `HARNESS_ALLOW_FULL_ACCESS`, `HARNESS_HOME`, ...) are tabulated in `README.md`.

## Architecture

A local GUI (projects → threads → chat) over the closed-source Claude Code binary, which a small Swift server runs as a child process and drives over its stream-json protocol. No framework, no bundler, no CDN and no third-party packages (Swift or JS); the point is that all of it stays readable and auditable. Keep it that way.

- `mac/Sources/CharnessCore/` — Foundation-only, builds on macOS and Linux:
  - `Server.swift` + `HTTP.swift` — loopback HTTP/1.1 + SSE server: token auth (token → `HttpOnly; SameSite=Strict` cookie), `Host`/`Origin`/`X-Harness` checks, CSP and security headers, REST routes under `/api/*`, the `models` list for the dropdown, runs and permission prompts, the read-only git panel.
  - `ClaudeProcess.swift` — starts `claude` with the flags/env the Agent SDK used, speaks stream-json, answers `can_use_tool` permission prompts. `Turn.swift` turns its messages into UI events and the live activity feed, and builds the child's environment from an allow-list (`AgentEnvironment`). `Mock.swift` is the mock backend.
  - `Guard.swift` — egress guard: a small CONNECT proxy the child is pointed at via `HTTPS_PROXY`; only `api.anthropic.com:443` plus user-allowed hosts are tunnelled, every attempt is logged to the Network panel.
  - `Store.swift` + `JSON.swift` — JSON persistence under `HARNESS_HOME` (default `~/.charness`, dirs 0700 / files 0600). `JSON.swift` mirrors `JSON.parse`/`JSON.stringify` exactly (key order, number formatting) so files stay byte-compatible.
  - `Uploads.swift` — attached files: `POST /api/threads/:id/files` (raw bytes, name in `X-File-Name`) stores them in `HARNESS_HOME/uploads/<threadId>/` (0700/0600, cleaned names); `/send` takes `files: [names]`, lists their paths in the prompt and gives Claude the folder (`--add-dir`). Never served back to the browser. Paths are built as strings, not `URL`, so macOS doesn't decompose Unicode names.
  - `Client.swift` — what the native screens run on: `APIClient` (loopback HTTP with the same token → cookie, `Origin` and `X-Harness` as the browser, so every server check applies), `EventStream` (the `/api/events` feed, reconnecting) and `ClientState`, a port of app.js's state `S` and `handleEvent` (uses `Reducer.apply`). `Markdown.swift` ports `md.js` to blocks and inline runs. Both are tested in `core-checks` (the client end to end against a mock server; Markdown against `mac/Fixtures/markdown.json`, which `node mac/Fixtures/make-markdown-fixtures.mjs` regenerates from md.js). `ShellPath.swift` reads the login shell's PATH for the app.
- `mac/Sources/Charness/` — the macOS app: runs `CharnessServer` in-process and shows native SwiftUI screens (`AppModel.swift` drives `Client.swift`; `Screens.swift`, `MessageViews.swift` only draw), or `public/` in a WKWebView when View ▸ Use Web Interface is on. File pickers via `NSOpenPanel`, API key from the Keychain item "charness", PATH from the login shell. SwiftUI can't be compiled on Linux: keep logic in `CharnessCore` and the views thin.
- `public/` — the browser UI. `reduce.js` folds agent events into the message list for the live view; the server saves threads with its twin `Reducer.swift`, so changing event shapes means changing both and regenerating `mac/Fixtures/reducer.json` (`node mac/Fixtures/make-reducer-fixtures.mjs`). `md.js` renders Markdown via DOM nodes, never `innerHTML`; `Markdown.swift` must give the same structure (regenerate `mac/Fixtures/markdown.json` after changing md.js).
- `mac/Fixtures/` — expected results for `core-checks`. Most were recorded from the retired Node version (`turns/*.json`: what the real Agent SDK reported for the strict stand-in `fake-claude.mjs`; `guard.json`; `env.json`; `node-home/`) and can no longer be regenerated; if Claude Code's protocol changes, `claude-spike` against the real binary is the check, and the recordings are updated by hand. `make-reducer-fixtures.mjs`, `make-js-format.mjs` and `make-markdown-fixtures.mjs` still regenerate theirs.

The server used to be Node (`server.mjs`, `lib/*.mjs`); see `SWIFT_PORT_PLAN.md` and git history.

Security posture is the product; preserve these invariants when changing code:
- The child process gets only an allow-listed env (no `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`...), telemetry/update checks forced off, and project/user `CLAUDE.md` and settings are not loaded unless the project opts in.
- Default permission mode asks before edits/commands. "Auto-accept edits & commands" (`commands`, opt-in per thread) is `acceptEdits` plus the server answering `Bash`/`BashOutput`/`KillShell` prompts itself (`Mode.autoAllow`, read from the thread's current mode at each prompt); every other tool still asks. The no-prompt mode exists only with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled.
- The UI must not use `innerHTML`, inline scripts/styles, or any non-same-origin request (strict CSP).
- The git "Changes" panel runs read-only git with `fsmonitor` and external diff/textconv disabled.

Adding behavior usually means touching a route in `mac/Sources/CharnessCore/Server.swift`, the matching UI code in `public/app.js` and in the native screens (`Client.swift` + `mac/Sources/Charness/`), and a check in `test/smoke.mjs` and/or `core-checks` (mock mode only; the real Claude Code path is not covered by tests — use `claude-spike`), then running `npm test` and `npm run check`. Rebuild the app (`./scripts/make-mac-app.sh`) to use the change there.

## Working rules

- Never suggest or offer to delete branches (local or remote). Only delete one if the user explicitly asks.
- When the user says "reboot server" (or "restart the server"), stop the running server, start it again with `npm start`, then open the new URL (with token) in the browser. Don't ask first.
