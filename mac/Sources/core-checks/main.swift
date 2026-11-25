// Self-test for CharnessCore, in the spirit of test/smoke.mjs: one plain program, no test framework, so it
// runs with only the Command Line Tools (no Xcode) and on Linux.
//     swift run --package-path mac core-checks
// Fixtures in mac/Fixtures are real output of the Node code; regenerate them with the scripts there.

import Foundation
import CharnessCore

var passed = 0
var failed = 0

func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
    do {
        if try condition() { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name)") }
    } catch {
        failed += 1
        print("  ✗ \(name) (threw: \(error))")
    }
}

func throwsError(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)
let fm = FileManager.default
var temps: [URL] = []

func tempDir() -> URL {
    let u = fm.temporaryDirectory.appendingPathComponent("charness-checks-\(UUID().uuidString)", isDirectory: true)
    temps.append(u)
    return u
}

func copyFixtureHome() throws -> URL {
    let home = tempDir()
    try fm.createDirectory(at: home.appendingPathComponent("threads"), withIntermediateDirectories: true)
    let src = fixtures.appendingPathComponent("node-home")
    try fm.copyItem(at: src.appendingPathComponent("state.json"), to: home.appendingPathComponent("state.json"))
    for f in try fm.contentsOfDirectory(atPath: src.appendingPathComponent("threads").path) {
        try fm.copyItem(at: src.appendingPathComponent("threads/\(f)"), to: home.appendingPathComponent("threads/\(f)"))
    }
    return home
}

func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

// MARK: - JSON vs JavaScript

print("JSON matches JavaScript (mac/Fixtures/js-format.tsv)")
do {
    let table = text(fixtures.appendingPathComponent("js-format.tsv")) ?? ""
    func decode(_ s: Substring) -> String { String(decoding: Data(base64Encoded: String(s)) ?? Data(), as: UTF8.self) }
    var cases = 0, mismatches: [String] = []
    for line in table.split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard f.count == 3 else { continue }
        cases += 1
        let input = decode(f[0])
        if f[1] == "!" {
            if !throwsError({ _ = try JSONValue.parse(input) }) { mismatches.append("accepted invalid \(input.debugDescription)") }
            continue
        }
        guard let v = try? JSONValue.parse(input) else { mismatches.append("rejected \(input.debugDescription)"); continue }
        let compact = v.jsonString(), pretty = v.jsonString(pretty: true)
        if compact != decode(f[1]) { mismatches.append("\(input.debugDescription): \(compact.debugDescription) vs JS \(decode(f[1]).debugDescription)") }
        if pretty != decode(f[2]) { mismatches.append("\(input.debugDescription) (pretty)") }
    }
    for m in mismatches { print("      \(m)") }
    check("\(cases) cases: same parse/reject decisions and byte-identical output as JSON.parse/stringify",
          cases > 50 && mismatches.isEmpty)
}
check("deeply nested input is rejected, not a crash", throwsError { _ = try JSONValue.parse(String(repeating: "[", count: 100_000)) })
check("lone surrogate escape becomes U+FFFD", try JSONValue.parse(#""a\ud800b""#) == .string("a\u{FFFD}b"))
check("key order is kept; equality ignores order",
      try (try JSONValue.parse(#"{"b":1,"a":2}"#)).jsonString() == #"{"b":1,"a":2}"#
      && (try JSONValue.parse(#"{"b":1,"a":2}"#)) == (try JSONValue.parse(#"{"a":2,"b":1}"#)))

// MARK: - store reads Node's files

print("store reads and rewrites Node's files")
do {
    let home = try copyFixtureHome()
    let store = try Store(home: home, readOnly: true)
    let st = store.state
    check("projects, threads, allow-list decoded",
          st.projects.count == 1 && st.projects[0].name == "proj" && st.threads.count == 2 && st.allowHosts == ["example.com"])
    let t0 = st.threads[0], t1 = st.threads[1]
    check("thread fields typed (title with accents and quotes, cost, session, timestamps)",
          t0.title == "Título con acentos y \"comillas\"" && t0.cost == 0.0084 && t0.sessionId?.hasPrefix("mock-") == true
          && t0.createdAt > 1.7e12 && t0.model == "claude-sonnet-5-5" && t0.mode == "edits")
    check("sessionId null reads as nil, cost 0", t1.sessionId == nil && t1.cost == 0 && t1.title == "New thread")
    check("state.json rewritten byte for byte",
          Store.stateFileText(st) == text(home.appendingPathComponent("state.json")))
    let msgs = try store.thread(t0.id)
    check("thread messages read (4 messages, emoji and control chars intact)",
          msgs.messages.count == 4
          && msgs.messages[0].objectValue?["text"]?.stringValue?.contains("ñandú 🚀 </script>") == true
          && msgs.messages[0].objectValue?["text"]?.stringValue?.contains("\u{1}") == true)
    var allIdentical = true
    for t in st.threads {
        let original = text(home.appendingPathComponent("threads/\(t.id).json"))
        if Store.threadFileText(try store.thread(t.id)) != original { allIdentical = false }
    }
    check("every thread file rewritten byte for byte", allIdentical)
    check("missing thread file reads as empty", try store.thread("abcdef012345").messages.isEmpty)
    check("read-only store refuses changes",
          throwsError { try store.updateState { $0.allowHosts.append("x") } }
          && throwsError { try store.deleteThreadFiles(t1.id) })
}

// MARK: - store writes

print("store writes like the Node version")
do {
    let home = tempDir().appendingPathComponent("nested/charness", isDirectory: true)
    check("read-only store on a missing folder creates nothing",
          (try? Store(home: home, readOnly: true)) != nil && !fm.fileExists(atPath: home.path))
    let store = try Store(home: home)
    check("folders created with mode 0700",
          StoreFiles.mode(home) == 0o700 && StoreFiles.mode(home.appendingPathComponent("threads")) == 0o700)
    let p = Project(id: Store.newId(), name: "demo", path: "/tmp/demo")
    let t = ChatThread(id: Store.newId(), projectId: p.id, title: "New thread", model: "claude-sonnet-5-5", mode: "edits", now: 1_795_549_492_135)
    try store.updateState { $0.projects.append(p); $0.threads.append(t) }
    try store.updateThread(t.id) { $0.messages.append(["role": "user", "text": "hi", "ts": 1_795_549_492_136]) }
    try store.flushAll()
    let stateFile = home.appendingPathComponent("state.json")
    check("files written with mode 0600", StoreFiles.mode(stateFile) == 0o600
          && StoreFiles.mode(home.appendingPathComponent("threads/\(t.id).json")) == 0o600)
    check("new thread has Node's field order",
          text(stateFile)?.contains(#""id": "\#(t.id)",\#n      "projectId": "\#(p.id)",\#n      "title": "New thread",\#n      "model": "claude-sonnet-5-5",\#n      "mode": "edits",\#n      "sessionId": null,\#n      "cost": 0,\#n      "createdAt": 1795549492135,\#n      "updatedAt": 1795549492135"#) == true)
    check("no temporary files left behind",
          try (try fm.contentsOfDirectory(atPath: home.path)).allSatisfy { !$0.hasSuffix(".tmp") }
          && (try fm.contentsOfDirectory(atPath: home.appendingPathComponent("threads").path)).allSatisfy { !$0.hasSuffix(".tmp") })
    let reopened = try Store(home: home)
    check("reopened store sees the same data",
          try reopened.state == store.state && (try reopened.thread(t.id)).messages.count == 1)

    try store.updateState { $0.allowHosts.append("api.example.org") }
    try store.updateThread(t.id) { $0.messages.append(["role": "system", "text": "later"]) }
    check("writes are debounced (nothing on disk right away)", text(stateFile)?.contains("api.example.org") == false)
    Thread.sleep(forTimeInterval: 0.7)
    check("debounced writes land on their own (state 200 ms, messages 400 ms)",
          try text(stateFile)?.contains("api.example.org") == true
          && (try Store(home: home, readOnly: true).thread(t.id)).messages.count == 2
          && store.lastWriteError == nil)

    try store.deleteThreadFiles(t.id)
    check("deleteThreadFiles removes the file and forgets the cache",
          try !fm.fileExists(atPath: home.appendingPathComponent("threads/\(t.id).json").path)
          && (try store.thread(t.id)).messages.isEmpty)
}

print("keeps what it doesn't know")
do {
    let home = try copyFixtureHome()
    let store = try Store(home: home)
    try store.updateState { s in
        s.raw["futureSetting"] = ["nested": [1, 2.5, true, nil]]
        var ps = s.projects
        ps[0].raw["loadClaudeMd"] = true
        s.projects = ps
        var ts = s.threads
        ts[0].title = "Renamed"
        s.threads = ts
    }
    try store.flushAll()
    let again = try Store(home: home, readOnly: true).state
    check("unknown fields survive a typed edit, in place",
          again.raw["futureSetting"] == ["nested": [1, 2.5, true, nil]]
          && again.projects[0].raw["loadClaudeMd"] == true
          && again.threads[0].title == "Renamed" && again.threads[0].cost == 0.0084
          && again.raw.keys == ["projects", "threads", "allowHosts", "futureSetting"])
}

print("refuses bad input")
do {
    let home = tempDir()
    try fm.createDirectory(at: home.appendingPathComponent("threads"), withIntermediateDirectories: true)
    try "{\"projects\": [".write(to: home.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    check("corrupt state.json is an error, not silently replaced", throwsError { _ = try Store(home: home) })
    try "{}".write(to: home.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    try "not json".write(to: home.appendingPathComponent("threads/abc123.json"), atomically: true, encoding: .utf8)
    let store = try Store(home: home)
    check("corrupt thread file is an error", throwsError { _ = try store.thread("abc123") })
    check("thread ids that aren't lowercase hex are refused (no ../ paths)",
          ["../state", "ABC123", "", "a/b", "abc.json", String(repeating: "a", count: 65)].allSatisfy { id in
              throwsError { _ = try store.thread(id) } && throwsError { try store.deleteThreadFiles(id) }
          })
    let ids = (0..<200).map { _ in Store.newId() }
    check("newId(): 12 hex characters, no repeats in 200", ids.allSatisfy { $0.count == 12 && Store.isValidId($0) } && Set(ids).count == 200)
}

// MARK: - Claude Code bridge (day 3)

print("talks to Claude Code like the Agent SDK")
let repo = fixtures.deletingLastPathComponent().deletingLastPathComponent()
let fakeClaude = fixtures.appendingPathComponent("fake-claude.mjs").path
do {
    var l = ClaudeLaunch(executable: "/x/claude", cwd: "/tmp")
    l.model = "claude-sonnet-5-5"; l.permissionMode = "acceptEdits"; l.resume = "prev-session"
    // exactly what Agent SDK 0.3.331 passed for runTurn's options (recorded with a stand-in binary)
    check("same flags as the Agent SDK", l.arguments == ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
        "--model=claude-sonnet-5-5", "--permission-prompt-tool=stdio", "--resume=prev-session", "--disallowedTools=AskUserQuestion",
        "--setting-sources=project", "--permission-mode=acceptEdits", "--include-partial-messages"])
    l.resume = nil; l.permissionMode = "default"; l.additionalDirectories = ["/home/me/.charness/uploads/abc123"]
    // recorded from the SDK with runTurn({ addDirs }) for a thread's attached files
    check("extra readable folders passed like the Agent SDK (--add-dir)", l.arguments == ["--output-format", "stream-json", "--verbose",
        "--input-format", "stream-json", "--model=claude-sonnet-5-5", "--permission-prompt-tool=stdio", "--disallowedTools=AskUserQuestion",
        "--setting-sources=project", "--permission-mode=default", "--include-partial-messages", "--add-dir=/home/me/.charness/uploads/abc123"])
    l.environment = ["PATH": "/usr/bin", "NODE_OPTIONS": "--require evil.js", "DEBUG": "*"]
    let env = l.childEnvironment
    check("entry point, session-state and crash-report variables set; NODE_OPTIONS and DEBUG dropped",
          env["CLAUDE_CODE_ENTRYPOINT"] == "sdk-cli" && env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == "1"
          && env["BUN_ENABLE_CRASH_REPORTING"] == "0" && env["NODE_OPTIONS"] == nil && env["DEBUG"] == nil && env["PATH"] == "/usr/bin")
}

func realPath(_ u: URL) -> String {
    guard let p = realpath(u.path, nil) else { return u.path }
    defer { free(p) }
    return String(cString: p)
}

// Records a turn the way make-turn-fixtures.mjs records the Node version: events, activity, prompts.
let denyMessage = "The user denied this action. Do not retry it; ask what they would like instead."
func record(_ turn: ClaudeTurn, cwd: String, allow: Bool?, stopAfter: Double? = nil, stopWhen: String = "Bash: sleep") -> (JSONValue, Double) {
    let lock = NSLock()
    var log: [JSONValue] = []
    var stopScheduled = false
    func add(_ v: JSONValue) { lock.lock(); log.append(v); lock.unlock() }
    turn.emit = { add(["kind": "event", "ev": $0]) }
    turn.activity = { a in
        add(["kind": "activity", "now": a.now.map(JSONValue.string) ?? .null, "steps": .array(a.steps.map(\.json))])
        if let ms = stopAfter, !stopScheduled, a.now?.hasPrefix(stopWhen) == true {
            stopScheduled = true
            DispatchQueue.global().asyncAfter(deadline: .now() + ms / 1000) { turn.stop() }
        }
    }
    turn.canUseTool = { req, answer in
        var e: JSONObject = ["kind": "permission", "name": .string(req.toolName), "input": req.input, "toolUseID": .string(req.toolUseId)]
        if let t = req.title { e["title"] = .string(t) }
        if let d = req.description { e["description"] = .string(d) }
        add(.object(e))
        guard let allow = allow else { return }   // nil: never answer (the user walked away)
        answer(allow ? .allow(updatedInput: req.input) : .deny(message: denyMessage, interrupt: false))
    }
    let t0 = Date()
    turn.run()
    let text = JSONValue.array(log).jsonString().replacingOccurrences(of: cwd, with: "$CWD")
        .replacingOccurrences(of: URL(fileURLWithPath: cwd).lastPathComponent, with: "$FOLDER")
    return ((try? JSONValue.parse(text)) ?? .null, Date().timeIntervalSince(t0))
}

/// The mock makes up random ids: number them in order of appearance, as make-turn-fixtures.mjs does.
func normalizeIds(_ v: JSONValue) -> JSONValue {
    var text = v.jsonString()
    let re = try! NSRegularExpression(pattern: "\\b(mock-[0-9a-z]+|toolu_[0-9a-z]+|msg_[0-9a-z_]+)\\b")
    var seen: [String: String] = [:]
    var counts: [String: Int] = [:]
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let id = String(text[Range(m.range, in: text)!])
        if seen[id] != nil { continue }
        let kind = id.hasPrefix("mock-") ? "SESSION" : id.hasPrefix("toolu_") ? "TOOLU" : "MSG"
        counts[kind, default: 0] += 1
        seen[id] = "$\(kind)_\(counts[kind]!)"
    }
    for (id, name) in seen.sorted(by: { $0.key.count > $1.key.count }) { text = text.replacingOccurrences(of: id, with: name) }
    return (try? JSONValue.parse(text)) ?? .null
}

func compare(_ name: String, _ got: JSONValue) -> Bool {
    guard let want = try? JSONValue.parse(Array((try? Data(contentsOf: fixtures.appendingPathComponent("turns/\(name).json"))) ?? Data())) else { return false }
    if want == got { return true }
    let a = want.arrayValue ?? [], b = got.arrayValue ?? []
    for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : .null) != (i < b.count ? b[i] : .null) {
        print("      first difference at entry \(i) of \(a.count) (Swift has \(b.count)):")
        print("        Node : \(i < a.count ? String(a[i].jsonString().prefix(220)) : "-")")
        print("        Swift: \(i < b.count ? String(b[i].jsonString().prefix(220)) : "-")")
        break
    }
    return false
}

func newCwd() -> String {
    let dir = tempDir()
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return realPath(dir)
}

if let node = ClaudeLaunch.which("node") {
    // the child's environment: same allow-list as lib/agent.mjs (ask Node itself, with a crafted environment)
    let crafted = ["PATH": "/usr/bin", "HOME": "/tmp/h", "lang": "es_CL.UTF-8", "ANTHROPIC_API_KEY": "sk-test",
                   "AWS_SECRET_ACCESS_KEY": "nope", "GITHUB_TOKEN": "nope", "SSH_AUTH_SOCK": "/nope", "NO_PROXY": "*",
                   "https_proxy": "http://evil:1", "HARNESS_PASS_ENV": "foo_var, BAR", "FOO_VAR": "1", "Bar": "2",
                   "DISABLE_TELEMETRY": "0", "NODE_OPTIONS": "--inspect"]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = ["--input-type=module", "-e", "const m = await import(process.argv[1]); process.stdout.write(JSON.stringify(m.buildEnv({ guardPort: 4321 })))",
                   repo.appendingPathComponent("lib/agent.mjs").path]
    p.environment = crafted
    let out = Pipe(); p.standardOutput = out
    try? p.run(); p.waitUntilExit()
    let nodeEnv = (try? JSONValue.parse(out.fileHandleForReading.readDataToEndOfFile()))?.objectValue
    let swiftEnv = AgentEnvironment.build(guardPort: 4321, crafted)
    check("child environment allow-list matches Node's buildEnv() (secrets dropped, guard proxy forced)",
          nodeEnv != nil && JSONValue.object(nodeEnv!) == .object(JSONObject(swiftEnv.map { ($0.key, JSONValue.string($0.value)) }))
          && swiftEnv["GITHUB_TOKEN"] == nil && swiftEnv["https_proxy"] == "http://127.0.0.1:4321")

    // whole turns against the stand-in, compared with what the Node version (real Agent SDK) reported
    func runTurnLog(prompt: String, allow: Bool?, resume: String?, stopAfter: Double? = nil, stopWhen: String = "Bash: sleep") -> (JSONValue, Double) {
        let cwd = newCwd()
        var launch = ClaudeLaunch(executable: node, cwd: cwd)
        launch.executableArgs = [fakeClaude]
        launch.model = "claude-sonnet-5-5"
        launch.permissionMode = "acceptEdits"
        launch.resume = resume
        launch.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin", "HOME": NSHomeDirectory()]
        return record(ClaudeTurn(launch: launch, prompt: prompt), cwd: cwd, allow: allow, stopAfter: stopAfter, stopWhen: stopWhen)
    }
    let (allowLog, allowSecs) = runTurnLog(prompt: "list the files", allow: true, resume: nil)
    check("approved command + sub-agent: same events, activity and prompt as Node", compare("allow", allowLog))
    // claude waits for more input until its stdin is closed; the stand-in gives up after 4 s
    check("the turn ends right after the result (stdin closed, like the SDK)", allowSecs < 2.5)
    check("denied edit, resumed session: same as Node", compare("deny", runTurnLog(prompt: "edit the readme", allow: false, resume: "prev-session-7").0))
    check("claude crashes (exit 3 + stderr): same error as Node", compare("crash", runTurnLog(prompt: "crash please", allow: true, resume: nil).0))
    check("Stop during a long command: same as Node", compare("stop", runTurnLog(prompt: "a slow command", allow: true, resume: nil, stopAfter: 300).0))

    let (waiting, secs) = runTurnLog(prompt: "list the files", allow: nil, resume: nil, stopAfter: 200, stopWhen: "Waiting for your approval")
    let wl = waiting.arrayValue ?? []
    check("Stop while a prompt is waiting ends the turn quickly with \"Stopped.\"",
          secs < 3 && wl.last == ["kind": "event", "ev": ["t": "error", "text": "Stopped."]])

    var missing = ClaudeLaunch(executable: "/nonexistent/claude", cwd: NSTemporaryDirectory())
    missing.environment = ["PATH": "/usr/bin"]
    let bad = ClaudeTurn(launch: missing, prompt: "hi")
    var badEvents: [JSONValue] = []
    bad.emit = { badEvents.append($0) }
    bad.run()
    check("a missing claude binary is reported, not a crash",
          badEvents.count == 1 && badEvents[0].objectValue?["text"]?.stringValue?.hasPrefix("Could not start Claude Code") == true)
} else {
    print("  - skipped: node not found on PATH (needed to run the Claude Code stand-in)")
}

print("built-in mock (npm run mock) without Node")
func mockLog(prompt: String, mode: String, allow: Bool?, resume: String?, stopAfter: Double? = nil, stopWhen: String = "") -> (JSONValue, Double) {
    let cwd = newCwd()
    let mock = MockClaude(cwd: cwd, model: "claude-sonnet-5-5", permissionMode: mode, resume: resume)
    return record(ClaudeTurn(backend: mock, prompt: prompt), cwd: cwd, allow: allow, stopAfter: stopAfter, stopWhen: stopWhen)
}
check("words split like JavaScript's /\\S+\\s*/g",
      MockClaude.words("\nAll done — ok.\n\n| a |  b") == ["All ", "done ", "— ", "ok.\n\n", "| ", "a ", "|  ", "b"])
/// Runs `body` on another thread; nil if it hasn't finished in time (a hang must fail the check, not the suite).
func within(_ seconds: Double, _ body: @escaping () -> (JSONValue, Double)) -> (JSONValue, Double)? {
    let done = DispatchSemaphore(value: 0)
    var result: (JSONValue, Double)?
    DispatchQueue.global().async { result = body(); done.signal() }
    return done.wait(timeout: .now() + seconds) == .success ? result : nil
}
let (mockAllow, mockAllowSecs) = mockLog(prompt: "hello there", mode: "default", allow: true, resume: nil)
check("mock, approved command + sub-agent: same as the Node mock", compare("mock-allow", normalizeIds(mockAllow)))
// its pauses (thinking 250 ms, 68 words x 12 ms, the command 2 x 400 ms, the sub-agent 4 x 200 ms) are what
// let you watch the live activity feed; they add up to about 2.7 s
check("mock takes its time like the Node mock (thinking, a running command, sub-agent steps)", mockAllowSecs >= 2.6)
check("mock, denied edit, resumed session: same as the Node mock", compare("mock-deny", normalizeIds(mockLog(prompt: "edit something", mode: "acceptEdits", allow: false, resume: "prev-session-9").0)))
check("mock, plan mode never asks or runs: same as the Node mock", compare("mock-plan", normalizeIds(mockLog(prompt: "show me the plan", mode: "plan", allow: true, resume: nil).0)))
do {
    let stopped: JSONValue = ["kind": "event", "ev": ["t": "error", "text": "Stopped."]]
    let waiting = within(10) { mockLog(prompt: "hello there", mode: "default", allow: nil, resume: nil, stopAfter: 100, stopWhen: "Waiting for your approval") }
    check("mock: Stop while a prompt waits ends the turn at once with \"Stopped.\"",
          waiting != nil && waiting!.1 < 2 && waiting!.0.arrayValue?.last == stopped)
    let writing = within(10) { mockLog(prompt: "hello there", mode: "default", allow: true, resume: nil, stopAfter: 50, stopWhen: "Writing") }
    let deltas = (writing?.0.arrayValue ?? []).filter { $0.objectValue?["ev"]?.objectValue?["t"] == "delta" }.count
    check("mock: Stop while it writes ends the turn at once with \"Stopped.\"",
          writing != nil && writing!.1 < 1.5 && deltas < 20 && writing!.0.arrayValue?.last == stopped)
}

for t in temps { try? fm.removeItem(at: t) }
print(failed == 0 ? "\nall \(passed) checks passed" : "\n\(failed) of \(passed + failed) checks FAILED")
exit(failed == 0 ? 0 : 1)
