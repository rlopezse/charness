# Swift port plan

Status: **proposal only**. No code has changed; the Node version stays the working implementation.

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
