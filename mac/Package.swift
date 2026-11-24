// swift-tools-version:5.9
// The Swift side of Charness. No third-party packages, on purpose (see CLAUDE.md).
//
//   CharnessCore   Foundation-only logic ported from Node, one piece at a time (builds on macOS and Linux)
//   Charness       the macOS app (AppKit + WKWebView); built into Charness.app by scripts/make-mac-app.sh
//   charness-check read-only check of your real ~/.charness data against the Swift store
//   core-checks    self-test for CharnessCore, like test/smoke.mjs: one plain program, no test framework,
//                  so it also runs with only the Command Line Tools (no Xcode needed)
import PackageDescription

let package = Package(
    name: "Charness",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "CharnessCore"),
        .executableTarget(name: "Charness", dependencies: ["CharnessCore"]),
        .executableTarget(name: "charness-check", dependencies: ["CharnessCore"]),
        .executableTarget(name: "core-checks", dependencies: ["CharnessCore"]),
    ]
)
