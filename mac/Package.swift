// swift-tools-version:5.9
// Charness: a native macOS app over Claude Code. No third-party packages, on purpose (see CLAUDE.md).
//
//   CharnessCore   Foundation-only: the loopback server, Claude Code bridge, egress guard, store, client state,
//                  Markdown (builds on macOS and Linux, so all of it is tested on Linux too)
//   Charness       the macOS app (AppKit + SwiftUI); built into Charness.app by scripts/make-mac-app.sh
//   core-checks    self-test: one plain program, no test framework, so it runs with only the Command Line
//                  Tools (no Xcode); also plays the Claude Code stand-in for its own turn checks (--fake-claude)
//   claude-spike   one turn with the real Claude Code in the terminal, approvals there
import PackageDescription

let package = Package(
    name: "Charness",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CharnessCore"),
        .executableTarget(name: "Charness", dependencies: ["CharnessCore"]),
        .executableTarget(name: "core-checks", dependencies: ["CharnessCore"]),
        .executableTarget(name: "claude-spike", dependencies: ["CharnessCore"]),
    ]
)
