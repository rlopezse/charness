// Day-3 spike: one turn with the REAL Claude Code, driven from Swift (no Node, no Agent SDK).
//     swift run --package-path mac claude-spike "what files are in this folder?"
//     swift run --package-path mac claude-spike --cwd ~/code/demo --mode acceptEdits "add a README"
//
// Options:
//   --cwd DIR        folder Claude works in (default: the current folder)
//   --mode MODE      default (asks before edits and commands) | acceptEdits | plan   (default: default)
//   --model ID       e.g. claude-sonnet-5-5
//   --resume ID      continue an earlier session (printed at the end of each run)
//   --claude PATH    the claude binary (default: HARNESS_CLAUDE_BIN, then the one bundled in node_modules,
//                    then `claude` on PATH)
//   --mock           no Claude at all: the built-in mock (like `npm run mock`), to try things safely
// Permission prompts are asked here in the terminal. Ctrl-C stops the turn.
// Unlike the app, this spike does NOT send Claude's traffic through the egress guard; the environment
// allow-list and telemetry switches do apply.

import Foundation
import CharnessCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let useMock = args.contains("--mock")
args.removeAll { $0 == "--mock" }
if args.contains("-h") || args.contains("--help") || args.isEmpty {
    print("usage: claude-spike [--cwd DIR] [--mode default|acceptEdits|plan] [--model ID] [--resume ID] [--claude PATH | --mock] \"prompt\"")
    exit(args.isEmpty ? 2 : 0)
}
let expand = { (p: String) in p.hasPrefix("~/") ? NSHomeDirectory() + p.dropFirst() : p }
let cwd = option("--cwd").map(expand) ?? FileManager.default.currentDirectoryPath
let mode = option("--mode") ?? "default"
let model = option("--model")
let resume = option("--resume")
let claudeOption = option("--claude").map(expand)
// for the test stand-in: --claude node --claude-arg mac/Fixtures/fake-claude.mjs (made absolute: claude runs in --cwd)
let claudeArgs = option("--claude-arg").map { [URL(fileURLWithPath: expand($0)).standardizedFileURL.path] } ?? []
let prompt = args.joined(separator: " ")

guard ["default", "acceptEdits", "plan"].contains(mode) else {
    FileHandle.standardError.write("--mode must be default, acceptEdits or plan\n".data(using: .utf8)!)
    exit(2)
}

// Find the claude binary: the one the Node app uses (bundled with the Agent SDK) unless told otherwise.
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
var machine = utsname()
uname(&machine)
let arch = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
let bundled = repo.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk-darwin-\(arch == "x86_64" ? "x64" : "arm64")/claude").path
let candidates = [claudeOption, ProcessInfo.processInfo.environment["HARNESS_CLAUDE_BIN"], bundled, ClaudeLaunch.which("claude")]
let found = useMock ? "(built-in mock)" : candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
guard let claude = found else {
    FileHandle.standardError.write("No claude binary found. Run `npm install` in \(repo.path), or pass --claude PATH.\n".data(using: .utf8)!)
    exit(1)
}

var launch = ClaudeLaunch(executable: claude, cwd: cwd)
launch.executableArgs = claudeArgs
launch.model = model
launch.permissionMode = mode
launch.resume = resume
launch.environment = AgentEnvironment.build(guardPort: nil)

let dim = isatty(1) != 0 ? ("\u{1B}[2m", "\u{1B}[0m") : ("", "")
let out = FileHandle.standardOutput
var atLineStart = true
let printLock = NSLock()
func put(_ s: String) {
    printLock.lock(); defer { printLock.unlock() }
    out.write(s.data(using: .utf8)!)
    if let last = s.last { atLineStart = last == "\n" }
}
func line(_ s: String) { put((atLineStart ? "" : "\n") + s + "\n") }

put("\(dim.0)claude: \(claude)\ncwd:    \(cwd)\nmode:   \(mode)\(model.map { "   model: \($0)" } ?? "")\(resume.map { "   resume: \($0)" } ?? "")\(dim.1)\n\n")

let turn = useMock
    ? ClaudeTurn(backend: MockClaude(cwd: cwd, model: model, permissionMode: mode, resume: resume), prompt: prompt)
    : ClaudeTurn(launch: launch, prompt: prompt)
var session: String?
var sawEnd = false
var sawError = false
var lastNow: String?

turn.emit = { ev in
    let e = ev.objectValue ?? JSONObject()
    switch e["t"]?.stringValue {
    case "session": session = e["sessionId"]?.stringValue
    case "delta": put(e["text"]?.stringValue ?? "")
    case "tool_use":
        line("⏺ \(e["name"]?.stringValue ?? "?")  \(toolSummary(e["name"]?.stringValue ?? "", e["input"]))")
    case "tool_result":
        let text = e["output"]?.stringValue ?? ""
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        line(e["isError"]?.boolValue == true ? "  ⎿ ✗ \(first.prefix(160))" : "  ⎿ ✓ \(n) line\(n == 1 ? "" : "s")")
    case "error":
        sawError = true
        line("✗ \(e["text"]?.stringValue ?? "")")
    case "end":
        sawEnd = true
        var bits: [String] = []
        if let c = e["cost"]?.doubleValue { bits.append(String(format: "$%.4f", c)) }
        if let t = e["turns"]?.doubleValue { bits.append("\(Int(t)) turn\(t == 1 ? "" : "s")") }
        if let ms = e["ms"]?.doubleValue { bits.append(String(format: "%.1fs", ms / 1000)) }
        line("\(dim.0)— \(bits.joined(separator: " · "))\(dim.1)")
    default: break
    }
}

turn.activity = { a in
    // the live status line, printed only when it changes (and not for plain streaming)
    guard a.now != lastNow else { return }
    lastNow = a.now
    if let now = a.now, now != "Writing…" { line("\(dim.0)· \(now)\(dim.1)") }
}

turn.canUseTool = { req, answer in
    DispatchQueue.global().async {   // don't block the message stream while the user decides
        line("? \(req.title ?? "Claude wants to use \(req.toolName)")")
        if let d = req.description, !d.isEmpty { line("  \(d)") }
        line("  \(toolSummary(req.toolName, req.input))")
        put("  Allow? [y/N] ")
        let reply = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        atLineStart = true
        if reply == "y" || reply == "yes" {
            answer(.allow(updatedInput: req.input))
        } else {
            answer(.deny(message: "The user denied this action. Do not retry it; ask what they would like instead.", interrupt: false))
        }
    }
}
turn.onPermissionCancelled = { _ in line("\(dim.0)(Claude withdrew the question)\(dim.1)") }

// Ctrl-C = Stop
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler { line("\(dim.0)stopping…\(dim.1)"); turn.stop() }
sigint.resume()

turn.run()
if let s = session { line("\(dim.0)session: \(s)   (continue with --resume \(s))\(dim.1)") }
exit(sawEnd && !sawError ? 0 : 1)
