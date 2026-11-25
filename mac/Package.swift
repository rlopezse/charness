// swift-tools-version:5.9
// The Swift side of Charness. No third-party packages, on purpose (see CLAUDE.md).
//
//   CharnessCore   Foundation-only logic ported from Node, one piece at a time (builds on macOS and Linux)
//   Charness       the macOS app (AppKit + SwiftUI, web UI as fallback); built into Charness.app by scripts/make-mac-app.sh
//   charness-check read-only check of your real ~/.charness data against the Swift store
//   claude-spike   one turn with the real Claude Code from Swift (no Node, no Agent SDK), approvals in the terminal
//   charness-server the whole Charness server in Swift (what Charness.app runs inside), for the terminal and tests
//   core-checks    self-test for CharnessCore, like test/smoke.mjs: one plain program, no test framework,
//                  so it also runs with only the Command Line Tools (no Xcode needed)
import PackageDescription

let package = Package(
    name: "Charness",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CharnessCore"),
        .executableTarget(name: "Charness", dependencies: ["CharnessCore"]),
        .executableTarget(name: "charness-check", dependencies: ["CharnessCore"]),
        .executableTarget(name: "core-checks", dependencies: ["CharnessCore"]),
        .executableTarget(name: "claude-spike", dependencies: ["CharnessCore"]),
        .executableTarget(name: "charness-server", dependencies: ["CharnessCore"]),
    ]
)
