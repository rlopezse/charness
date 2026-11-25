# Swift port plan

Status: **in progress** on branch `feat/swift-port`, one step per day; the app works at the end of each day.
Node stays the working implementation (and the only writer of `~/.charness`) until the swap-over (day 7).

## Progress

| Day | Step | Status |
|---|---|---|
| 1 | Native window: `Charness.app` is Swift (AppKit + WKWebView) around the Node server | done |
| 2 | Swift package in `mac/`; `store.mjs` → `CharnessCore/Store.swift` (+ `JSON.swift`), read-only for now | done |
| 3 | Drive the `claude` binary over `stream-json` from Swift, incl. permission prompts (go / no-go) | done: **go** (verified on the Mac) |
| 4 | Child env allow-list (`buildEnv`/`baseEnv`) and mock backend (`npm run mock` without Node) | done |
| 5 | Reducer (`reduce.js`) with golden tests against the JS version | next |
| 6 | Egress guard on Network.framework | |
| 7-8 | Swap-over: Swift answers `/api` for the existing web UI; Node no longer needed | |
| 9 | Git Changes panel | |
| 10-14 | Native SwiftUI screens (optional) | |
| 15 | Tests and packaging | |

Day 4 notes: `Mock.swift` ports `mockQuery()`; a turn now takes any `ClaudeBackend` (the real process or the
mock). The Swift mock reproduces the Node mock's events, activity and prompts exactly (approve + sub-agent,
deny + resume, plan mode; its random ids are numbered in order of appearance before comparing), Stop works
while a prompt waits or while it writes, and `claude-spike --mock` runs it in the terminal. The environment
allow-list (the other half of day 4) was ported on day 3 and is compared with Node's `buildEnv()`.

Day 3 notes: the protocol was captured by pointing the real Agent SDK at a recording stand-in binary
(flags, environment, `initialize`, the user message, `can_use_tool` and its answer). `ClaudeProcess.swift`
speaks it; `Turn.swift` ports `runTurn()` (UI events + live activity). Both Node (real SDK) and Swift drive
the same strict stand-in (`mac/Fixtures/fake-claude.mjs`) through four scenarios (approve + sub-agent, deny +
resume, crash, Stop) and must report identical events; they do. Differences from the SDK, on purpose:
`CLAUDE_CODE_ENTRYPOINT=sdk-cli` (the SDK says `sdk-ts`) and no `CLAUDE_AGENT_SDK_VERSION`. The real go/no-go
is `claude-spike` against the real binary: the stand-in can only be as faithful as what was captured.
Verified on the Mac (2026-11-25) with the bundled Claude Code 2.1.331: streamed reply, Read and Bash
(auto-allowed as read-only), a Write that raised the permission prompt, was approved in the terminal and
created the file, cost and session id reported. Not yet tried with the real binary: --resume and Stop. Also
fixed in Node: a crash showed Claude Code's stderr twice in the error message.

Day 2 notes: no official Swift Agent SDK exists (checked Nov 2026; only community packages, which the
no-third-party-code rule excludes). The store refuses a corrupt `state.json` instead of starting empty and
overwriting it, as Node does. Its JSON layer mirrors `JSON.parse`/`JSON.stringify` exactly (64 cases checked
against real JavaScript output), so Swift can rewrite Node's files byte for byte.

## Summary

A Swift port is feasible and is mostly a UI port. The hard part is the Claude Agent SDK, which, as far as we know, has no official Swift version (unverified: confirm before starting).

## Component mapping

| Today | In Swift | Effort |
|---|---|---|
| `public/` (UI, Markdown, CSS, ~850 lines) | SwiftUI views; `AttributedString(markdown:)` or a custom renderer | Largest chunk |
| `server.mjs` (HTTP, SSE, token, CSP, Origin checks) | Mostly disappears: a native app has no web attack surface | Negative work |
| `lib/agent.mjs` (SDK bridge, env allow-list, mock) | `Foundation.Process` launching the `claude` binary with a filtered environment | Hardest part |
| `lib/guard.mjs` (CONNECT proxy) | `NWListener` (Network.framework), roughly 2-3x the lines | Medium |
| `lib/store.mjs` (JSON, 0600/0700) | `Codable` + `FileManager` with POSIX permissions | Easy |
| `public/reduce.js` (shared reducer) | Swift enum of events + reducer; server/browser sharing no longer needed | Easy |
| `test/smoke.mjs` | Swift Testing or XCTest with a protocol-based mock backend | Medium |
| `scripts/make-mac-app.sh`, `launch.sh` | Xcode target, signing, notarization | Medium |

## Main risks

- **No Swift SDK.** Two options:
  - (a) Spawn the CLI and speak its `stream-json` protocol directly. This means reimplementing the permission-approval flow (`canUseTool`), which is the core of the app.
  - (b) Bundle a Node sidecar running the existing SDK. Keeps Node as a dependency and defeats much of the rewrite.
- **App Sandbox.** Spawning `claude` and reading arbitrary project folders needs entitlements or security-scoped bookmarks. Shipping unsandboxed is easier but weakens the security story.
- **Third-party code.** Browser access would need an HTTP server dependency (e.g. Hummingbird), breaking the "no third-party code" principle.
- **Platform.** Linux and Windows support is lost.

## Estimate (rough guess, not measured)

- Working chat with approvals: ~1 week for someone who knows SwiftUI.
- Parity (guard, git panel, Network panel, tests, packaging): ~3-4 weeks.

## Options

1. **Keep Node, add a native shell (recommended for a native Mac feel).** SwiftUI + `WKWebView` wrapping the existing server. A few days of work; keeps all current security work.
2. **Full Swift rewrite.** Only worth it to drop Node entirely. Prototype the CLI `stream-json` protocol and the permission flow first, since they decide feasibility.

## Suggested first steps if this is ever started

1. Verify whether an official Swift SDK exists.
2. Prototype spawning `claude` with `--input-format stream-json --output-format stream-json` and handling a permission request end to end.
3. Decide on sandboxed vs unsandboxed distribution.
4. Port in this order: store, reducer, agent bridge, guard, UI, tests, packaging.
