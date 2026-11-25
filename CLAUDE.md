# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm install                 # Node >= 20; single pinned dependency: @anthropic-ai/claude-agent-sdk
npm start                   # real backend; prints http://127.0.0.1:4317/?token=... (open that link once)
npm run mock                # fake backend, no network / API key needed (node server.mjs --mock)
npm test                    # node test/smoke.mjs — end-to-end checks run against a --mock server
./scripts/make-mac-app.sh   # builds the Swift package in mac/ into ~/Applications/Charness.app
swift run --package-path mac core-checks     # Swift self-test (also runs on Linux; no Xcode needed)
swift run --package-path mac charness-check  # read-only: does the Swift store rewrite ~/.charness byte for byte?
swift run --package-path mac claude-spike "prompt"   # one real Claude Code turn from Swift (no Node), approvals in the terminal
```

There is no linter or build step, and no test runner: `test/smoke.mjs` is one script that spawns the server in mock mode (random port, temp `HARNESS_HOME`) and asserts on it, so it can't run a single test in isolation. Server flags/env vars (`--port`, `--rotate-token`, `--no-guard`, `HARNESS_ALLOW_HOSTS`, `HARNESS_PASS_ENV`, `HARNESS_ALLOW_FULL_ACCESS`, `HARNESS_HOME`, ...) are tabulated in `README.md`.

## Architecture

A local GUI (projects → threads → chat) over the Claude Agent SDK, which runs the closed-source Claude Code binary as a child process. The repo is plain ESM with no framework, no bundler and no CDN; the point is that all of it stays readable and auditable. Keep it that way (no third-party UI/runtime deps).

- `server.mjs` — HTTP + SSE server: token auth, `Host`/`Origin` checks, CSP, REST routes under `/api/*`, and the `MODELS` list for the dropdown. Loopback only.
- `lib/agent.mjs` — bridge to the Agent SDK (`runTurn`), builds the child's environment from an allow-list (`baseEnv`/`buildEnv`), and contains the mock backend.
- `lib/guard.mjs` — egress guard: a small CONNECT proxy the child is pointed at via `HTTPS_PROXY`; only `api.anthropic.com:443` plus user-allowed hosts are tunnelled, every attempt is logged to the Network panel.
- `lib/uploads.mjs` — attached files: `POST /api/threads/:id/files` (raw bytes, name in `X-File-Name`) stores them in `HARNESS_HOME/uploads/<threadId>/` (0700/0600, cleaned names); `/send` takes `files: [names]`, lists their paths in the prompt and passes the folder as `addDirs` (`--add-dir`). Never served back to the browser.
- `lib/store.mjs` — JSON persistence under `HARNESS_HOME` (default `~/.charness`, dirs 0700 / files 0600): state, per-thread message files, access token.
- `public/` — the browser UI. `reduce.js` is the key shared piece: it folds agent events into the message list and is imported by **both** the server (to persist threads) and the browser (to render live), so changing event shapes means updating it for both sides. `md.js` renders Markdown via DOM nodes, never `innerHTML`.

- `mac/` — the Swift migration (see `SWIFT_PORT_PLAN.md`). `Sources/Charness` is the macOS app (a WKWebView window over the Node server, started via `scripts/launch.sh`). `Sources/CharnessCore` holds Foundation-only ports of the Node modules; until the swap-over day they must read and rewrite Node's files byte for byte (`JSON.swift` mirrors `JSON.parse`/`JSON.stringify`) and keep unknown fields, and Node stays the only writer of `~/.charness`. `ClaudeProcess.swift`/`Turn.swift` drive the `claude` binary over its stream-json protocol without the SDK (`Mock.swift` ports the mock backend, and must match `mockQuery()` the same way); `mac/Fixtures/fake-claude.mjs` is a strict stand-in for that binary, and `mac/Fixtures/turns/*.json` record what `runTurn()` (real SDK) reports against it, which the Swift turn must match exactly — so a change to `runTurn()`'s events or activity feed means regenerating them (`node mac/Fixtures/make-turn-fixtures.mjs`) and updating `Turn.swift`. Fixtures in `mac/Fixtures` are real Node output; regenerate them with the `.mjs` scripts there when the data format changes.

Security posture is the product; preserve these invariants when changing code:
- The child process gets only an allow-listed env (no `AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`...), telemetry/update checks forced off, and project/user `CLAUDE.md` and settings are not loaded unless the project opts in.
- Default permission mode asks before edits/commands; the no-prompt mode exists only with `HARNESS_ALLOW_FULL_ACCESS=1`. `AskUserQuestion` is disabled.
- The UI must not use `innerHTML`, inline scripts/styles, or any non-same-origin request (strict CSP).
- The git "Changes" panel runs read-only git with `fsmonitor` and external diff/textconv disabled.

Adding behavior usually means touching a route in `server.mjs`, the matching UI code in `public/app.js`, and a check in `test/smoke.mjs` (mock mode only; the real SDK path is not covered by tests).

## Working rules

- Never suggest or offer to delete branches (local or remote). Only delete one if the user explicitly asks.
- When the user says "reboot server" (or "restart the server"), stop the running server, start it again with `npm start`, then open the new URL (with token) in the browser. Don't ask first.
