// Self-test for CharnessCore: one plain program, no test framework, so it
// runs with only the Command Line Tools (no Xcode) and on Linux.
//     swift run --package-path mac core-checks
// Fixtures in mac/Fixtures are real output of the retired Node version and web UI (and of JavaScript itself),
// kept as the expected results; they can't be regenerated, so new behaviour gets new checks written by hand.
// It also plays the Claude Code stand-in for its own turn checks: `core-checks --fake-claude` (FakeClaude.swift).

import Foundation
import CharnessCore

if CommandLine.arguments.dropFirst().first == "--fake-claude" { FakeClaude.run(Array(CommandLine.arguments.dropFirst(2))) }

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

// MARK: - reducer (day 5)

print("reducer matches the web UI's reduce.js (mac/Fixtures/reducer.json)")
do {
    let golden = (try? JSONValue.parse(Array((try? Data(contentsOf: fixtures.appendingPathComponent("reducer.json"))) ?? Data())))?.objectValue
    let sequences = golden?["sequences"]?.arrayValue ?? []
    var failures: [String] = []
    var events = 0
    for sq in sequences.compactMap(\.objectValue) {
        let name = sq["name"]?.stringValue ?? "?"
        let evs = sq["events"]?.arrayValue ?? []
        let wantIdx = sq["indexes"]?.arrayValue?.compactMap(\.doubleValue).map(Int.init) ?? []
        let snaps = sq["snapshots"]?.arrayValue?.compactMap(\.stringValue)
        var msgs: [JSONValue] = []
        var idx: [Int] = []
        for (n, ev) in evs.enumerated() {
            idx.append(Reducer.apply(&msgs, ev))
            events += 1
            if let snaps = snaps, n < snaps.count, JSONValue.array(msgs).jsonString() != snaps[n] {
                failures.append("\(name): after event \(n): \(String(JSONValue.array(msgs).jsonString().prefix(160)))")
                break
            }
        }
        if idx != wantIdx { failures.append("\(name): returned \(idx), JS returned \(wantIdx)") }
        if JSONValue.array(msgs).jsonString() != sq["final"]?.stringValue { failures.append("\(name): final thread differs") }
    }
    for f in failures.prefix(5) { print("      \(f)") }
    check("\(sequences.count) event sequences (\(events) events): same changed-message index and byte-identical thread every time",
          sequences.count >= 25 && failures.isEmpty)

    let summaries = golden?["toolSummary"]?.arrayValue?.compactMap(\.objectValue) ?? []
    let wrong = summaries.filter { c in
        let input = c["input"] == .null ? nil : c["input"]
        return toolSummary(c["name"]?.stringValue ?? "", input) != c["summary"]?.stringValue
    }
    for c in wrong.prefix(3) {
        print("      \(c["name"]?.stringValue ?? ""): \(toolSummary(c["name"]?.stringValue ?? "", c["input"]).debugDescription) vs JS \(c["summary"]?.stringValue?.debugDescription ?? "-")")
    }
    check("toolSummary() matches the JS on \(summaries.count) cases", summaries.count >= 20 && wrong.isEmpty)

    // a very long streamed answer stays fast: the text grows in place instead of being copied for every
    // word (copying would move ~100 GB here and take minutes)
    var msgs: [JSONValue] = []
    let t0 = Date()
    for _ in 0..<200_000 { Reducer.apply(&msgs, ["t": "delta", "text": "word "]) }
    let secs = Date().timeIntervalSince(t0)
    check("200,000 streamed words (1 MB of text) fold in well under 3 s (\(String(format: "%.2f", secs)) s)",
          secs < 3 && msgs.first?.objectValue?["blocks"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?.utf8.count == 1_000_000)
}

// MARK: - egress guard (day 6)

print("egress guard answers like the Node guard did (mac/Fixtures/guard.json)")
check("allow-list rules: exact host, default port 443, explicit port, *.subdomains only, case-insensitive", [
    EgressGuard.isAllowed(host: "api.anthropic.com", port: 443, allow: ["api.anthropic.com"]),
    !EgressGuard.isAllowed(host: "api.anthropic.com", port: 8443, allow: ["api.anthropic.com"]),
    EgressGuard.isAllowed(host: "localhost", port: 8080, allow: ["localhost:8080"]),
    EgressGuard.isAllowed(host: "a.b.example.org", port: 443, allow: ["*.example.org"]),
    !EgressGuard.isAllowed(host: "example.org", port: 443, allow: ["*.example.org"]),
    !EgressGuard.isAllowed(host: "badexample.org", port: 443, allow: ["*.example.org"]),
    EgressGuard.isAllowed(host: "API.Anthropic.COM", port: 443, allow: ["api.ANTHROPIC.com"]),
    EgressGuard.isAllowed(host: "x", port: 443, allow: ["x:0443"]),
    !EgressGuard.isAllowed(host: "x", port: 443, allow: ["x:"]),
    !EgressGuard.isAllowed(host: "evil.com", port: 443, allow: []),
].allSatisfy { $0 })

/// Sends raw bytes to 127.0.0.1:port and returns everything received until the other side closes
/// (or `marker` shows up, or nothing arrives for 3 s).
func probe(_ port: Int, _ request: String, until marker: String? = nil) -> String {
    guard let fd = Net.connect(host: "127.0.0.1", port: port) else { return "<cannot connect>" }
    defer { _ = close(fd) }
    Net.setReceiveTimeout(fd, 3)
    Net.sendAll(fd, Array(request.utf8))
    var got: [UInt8] = []
    while let chunk = Net.receive(fd) {
        got += chunk
        if let m = marker, String(decoding: got, as: UTF8.self).contains(m) { break }
    }
    return String(decoding: got, as: UTF8.self)
}

let guardGolden = (try? JSONValue.parse(Array((try? Data(contentsOf: fixtures.appendingPathComponent("guard.json"))) ?? Data())))?.objectValue
/// Lines the guard test servers log, kept across threads.
final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [JSONObject] = []
    func add(_ o: JSONObject) { lock.lock(); items.append(o); lock.unlock() }
    var all: [JSONObject] { lock.lock(); defer { lock.unlock() }; return items }
}

if let golden = guardGolden {
    // the servers the guards tunnel to: one that greets and closes, one that answers the first bytes it gets, and
    // a fake corporate proxy that requires a login (ported from the retired guard-servers.mjs). The answers they
    // are compared with were recorded from the Node guard before it was retired (mac/Fixtures/guard.json).
    let helperLog = LineLog()
    let echoServer = try? Net.serve { s in _ = Net.sendAll(s, Array("hello-from-echo".utf8)); Net.finish(s) }
    let pongServer = try? Net.serve { s in
        if let d = Net.receive(s) { _ = Net.sendAll(s, Array("PONG:".utf8) + d) }
        Net.finish(s)
    }
    let echoPort = echoServer?.port ?? 0
    let proxyServer = try? Net.serve { s in
        var buf: [UInt8] = []
        while let chunk = Net.receive(s) {
            buf += chunk
            guard let i = Net.find([13, 10, 13, 10], in: buf) else { continue }
            let head = String(decoding: buf[..<(i + 4)], as: UTF8.self)
            helperLog.add(["proxyRequest": .string(head)])
            if head.hasPrefix("CONNECT 127.0.0.1:\(echoPort) "), head.contains("Proxy-Authorization: Basic dXNAZXI6cEBzcw==\r\n"),
               let up = Net.connect(host: "127.0.0.1", port: echoPort) {
                _ = Net.sendAll(s, Array("HTTP/1.1 200 Connection established\r\nVia: fake-proxy\r\n\r\n".utf8))
                Net.pump(s, up)
                _ = close(up)
            } else {
                _ = Net.sendAll(s, Array("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
                Net.finish(s)
            }
            return
        }
    }
    var ready: JSONObject?
    if let e = echoServer, let p = pongServer, let x = proxyServer {
        ready = ["echo": .number(Double(e.port)), "pong": .number(Double(p.port)), "proxy": .number(Double(x.port))]
    }
    if let ready = ready {
        let port = { (k: String) in Int(ready[k]?.doubleValue ?? 0) }
        let ports = [("{ECHO}", port("echo")), ("{PONG}", port("pong")), ("{PROXY}", port("proxy"))]
        func fill(_ s: String) -> String { ports.reduce(s) { $0.replacingOccurrences(of: $1.0, with: String($1.1)) } }
        func tokens(_ s: String) -> String {
            ports.reduce(s) { text, p in
                (try? NSRegularExpression(pattern: "\\b\(p.1)\\b")).map {
                    $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: p.0))
                } ?? text
            }
        }
        let allow = golden["allow"]?.arrayValue?.compactMap(\.stringValue).map(fill) ?? []
        let swiftLock = NSLock()
        var swiftLog: [(String, GuardLogEntry)] = []
        let direct = EgressGuard(allowList: { allow }) { e in swiftLock.lock(); swiftLog.append(("direct", e)); swiftLock.unlock() }
        let chained = EgressGuard(allowList: { allow }, upstream: fill(golden["upstream"]?.stringValue ?? "")) { e in
            swiftLock.lock(); swiftLog.append(("chained", e)); swiftLock.unlock()
        }
        let swiftDirect = (try? direct.start()) ?? 0, swiftChained = (try? chained.start()) ?? 0

        // plain-HTTP answers are compared by status line and body: Node added a Date header and kept the
        // connection open, the Swift guard closes it
        let blocked = "blocked by charness egress guard\n"
        func normal(_ r: String, plain: Bool) -> String {
            guard plain else { return r }
            return (r.components(separatedBy: "\r\n").first ?? "") + (r.contains(blocked) ? " | " + blocked : " | no body")
        }
        let probes = golden["probes"]?.arrayValue?.compactMap(\.objectValue) ?? []
        var mismatches: [String] = []
        for pr in probes {
            let plain = pr["plain"] == true
            let got = probe(pr["chained"] == true ? swiftChained : swiftDirect, fill(pr["request"]?.stringValue ?? ""), until: plain ? blocked : nil)
            let want = pr["answer"]?.stringValue ?? "?"
            if tokens(normal(got, plain: plain)) != want {
                mismatches.append("\(pr["name"]?.stringValue ?? "?"): Node said \(want.prefix(70).debugDescription), Swift \(got.prefix(70).debugDescription)")
            }
        }
        for m in mismatches.prefix(5) { print("      \(m)") }
        check("\(probes.count) requests (allowed, refused, malformed, plain http, chained): the answers the Node guard gave",
              probes.count >= 20 && mismatches.isEmpty)

        Thread.sleep(forTimeInterval: 0.5)
        let lines = helperLog.all
        swiftLock.lock(); let mine = swiftLog; swiftLock.unlock()
        func noTs(_ o: JSONObject) -> JSONValue { var c = o; c["ts"] = nil; return .object(c) }
        let swiftLogText = tokens(JSONValue.array(mine.map { g, e -> JSONValue in ["guard": .string(g), "entry": noTs(e.json.objectValue!)] }).jsonString())
        check("the same \(mine.count) log entries the Node guard wrote, in the same order (host, port, allowed, note)",
              !mine.isEmpty && swiftLogText == golden["log"]?.stringValue)

        let proxyRequests = lines.compactMap { $0["proxyRequest"]?.stringValue }.map(tokens)
        check("the same requests to the user's proxy, with Proxy-Authorization from the URL's login",
              JSONValue.array(proxyRequests.map(JSONValue.string)) == golden["proxyRequests"]
              && proxyRequests.first?.contains("Proxy-Authorization: Basic dXNAZXI6cEBzcw==\r\n") == true)

        direct.stop(); chained.stop()
        check("after stop() the guard accepts no connections", probe(swiftDirect, "CONNECT 127.0.0.1:\(port("echo")) HTTP/1.1\r\n\r\n") == "<cannot connect>")
    } else {
        check("the guard test servers started", false)
    }
    echoServer?.stop(); pongServer?.stop(); proxyServer?.stop()
} else {
    check("mac/Fixtures/guard.json is readable", false)
}

// MARK: - server paths (days 7-8)

print("server paths are handled like Node's")
do {
    let base = URL(fileURLWithPath: realPath(tempDir().deletingLastPathComponent()))
    let dir = base.appendingPathComponent("charness-paths-\(UUID().uuidString)").path
    temps.append(URL(fileURLWithPath: dir))
    let nfc = "Código ñ"                                   // precomposed: ó and ñ as one character each
    let nfd = "Co\u{301}digo n\u{303}"                      // decomposed: o + ´, n + ~
    _ = mkdir(dir, 0o700); _ = mkdir(dir + "/" + nfc, 0o700); _ = mkdir(dir + "/real", 0o700)
    _ = symlink(dir + "/real", dir + "/link")
    _ = symlink("../real", dir + "/real/up")
    let got = CharnessServer.realPath(dir + "/" + nfc)
    check("realPath keeps the name's bytes as given (no decomposition) and follows symlinks",
          got.map { Array($0.utf8) } == Array((dir + "/" + nfc).utf8)
          && CharnessServer.realPath(dir + "/link/up/./") == dir + "/real"
          && CharnessServer.realPath(dir + "/missing") == nil
          && Array(nfc.utf8) != Array(nfd.utf8))   // (the two spellings really are different bytes)
    check("resolve() like path.resolve()", CharnessServer.resolve("a/./b/../c//", cwd: "/x/y") == "/x/y/a/c"
          && CharnessServer.resolve("/../..", cwd: "/x") == "/" && CharnessServer.resolve("", cwd: "/x/y") == "/x/y")
    let up = Uploads(home: URL(fileURLWithPath: dir))
    let saved = try? up.save("abc123", name: "foto \(nfc).png", bytes: [1, 2, 3])
    let listed = (try? FileManager.default.contentsOfDirectory(atPath: up.dir("abc123"))) ?? []
    check("uploaded file names are stored with exactly the bytes they came with",
          saved?.name == "foto \(nfc).png" && listed.count == 1
          && listed.first.map { Array($0.utf8) } == Array("foto \(nfc).png".utf8) && up.find("abc123", .string("foto \(nfc).png"))?.size == 3)
}

// MARK: - Claude Code bridge (day 3)

print("talks to Claude Code like the Agent SDK")
/// This program itself plays the Claude Code stand-in (FakeClaude.swift) when started with --fake-claude.
let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
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

// Records a turn the way the Node version was recorded (mac/Fixtures/turns): events, activity, prompts.
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

/// The mock makes up random ids: number them in order of appearance, as was done for the recordings.
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

// the child's environment: the allow-list lib/agent.mjs had (recorded with a crafted environment, mac/Fixtures/env.json)
if let env = (try? JSONValue.parse(Array((try? Data(contentsOf: fixtures.appendingPathComponent("env.json"))) ?? Data())))?.objectValue,
   let input = env["input"]?.objectValue {
    let crafted = Dictionary(uniqueKeysWithValues: input.entries.compactMap { e in e.value.stringValue.map { (e.key, $0) } })
    let swiftEnv = AgentEnvironment.build(guardPort: 4321, crafted)
    let swiftBase = AgentEnvironment.base(crafted)
    func json(_ d: [String: String]) -> JSONValue { .object(JSONObject(d.map { ($0.key, JSONValue.string($0.value)) })) }
    check("child environment allow-list matches what Node's buildEnv() gave (secrets dropped, guard proxy forced)",
          json(swiftEnv) == env["build"] && json(swiftBase) == env["base"]
          && swiftEnv["GITHUB_TOKEN"] == nil && swiftEnv["https_proxy"] == "http://127.0.0.1:4321")
} else {
    check("mac/Fixtures/env.json is readable", false)
}

do {
    // whole turns against the stand-in, compared with what the Node version (real Agent SDK) reported
    // (mac/Fixtures/turns/*.json, recorded before the Node server was retired)
    func runTurnLog(prompt: String, allow: Bool?, resume: String?, stopAfter: Double? = nil, stopWhen: String = "Bash: sleep") -> (JSONValue, Double) {
        let cwd = newCwd()
        var launch = ClaudeLaunch(executable: selfPath, cwd: cwd)
        launch.executableArgs = ["--fake-claude"]
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
}

print("built-in mock")
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

// MARK: - native screens' client (SwiftUI)

print("the app's client talks to a real server (mock)")
do {
    var cfg = ServerConfig(environment: [:])
    cfg.home = tempDir(); cfg.port = 0; cfg.mock = true; cfg.guardOn = false
    let server = try CharnessServer(config: cfg)
    try server.start()
    defer { server.stop() }

    let bad = APIClient(port: server.port)
    check("a wrong access token gets no session", throwsError { try bad.login(token: "nope") }
          && throwsError { try bad.request("GET", "/api/state") })
    let api = APIClient(port: server.port)
    try api.login(token: server.token)

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var st = ClientState()
        var connects = 0
        var seen: [String] = []
        func with<T>(_ f: (Box) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }
    }
    let box = Box()
    func withState<T>(_ f: (inout ClientState) -> T) -> T { box.with { f(&$0.st) } }
    func waitFor(_ secs: Double, _ cond: (ClientState) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if withState({ cond($0) }) { return true }; usleep(20_000) }
        return false
    }
    let stream = EventStream(client: api, onEvent: { ev in
        let follow = box.with { b -> ClientState.FollowUp in
            b.seen.append(ev.objectValue?["type"]?.stringValue ?? "?")
            return b.st.handle(ev)
        }
        if follow == .refreshState, let v = try? api.request("GET", "/api/state") { box.with { $0.st.applyState(v) } }
    }, onConnection: { up in box.with { b in b.st.connected = up; if up { b.connects += 1 } } })
    stream.start()
    check("the live-event feed connects with the session cookie", waitFor(5) { $0.connected })

    withState { $0.applyState((try? api.request("GET", "/api/state")) ?? .null) }
    check("state: mock flag, models and modes",
          withState { $0.mock && $0.models.first?.id == "" && $0.modes.map(\.id) == ["ask", "edits", "commands", "plan"] })

    let made = tempDir()
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let folder = CharnessServer.realPath(made.path) ?? made.path
    let p = try api.request("POST", "/api/projects", ["path": .string(folder)])
    let pid = p.objectValue?["id"]?.stringValue ?? ""
    let t = try api.request("POST", "/api/threads", ["projectId": .string(pid)])
    let tid = t.objectValue?["id"]?.stringValue ?? ""
    check("a 'state' event makes the client refresh: the new project and thread show up",
          waitFor(5) { $0.projects.contains { $0.id == pid } && $0.threads(of: pid).map(\.id) == [tid] })
    withState { $0.applyThread((try? api.request("GET", "/api/threads/\(tid)")) ?? .null) }
    check("opening a thread", withState { $0.current?.thread.id == tid && $0.messages.isEmpty })

    let caught: String? = { do { try api.request("PATCH", "/api/threads/nope", ["title": "x"]); return nil }
                            catch let e as APIError { return "\(e.status) \(e.message)" } catch { return "\(error)" } }()
    check("a failed call carries the server's error text", caught?.hasPrefix("404 ") == true && caught != "404 Not Found")

    let name = "foto ñ \u{1F600}.png"
    let up = try api.upload(threadId: tid, name: name, bytes: [137, 80, 78, 71])
    check("upload keeps a non-ASCII file name", up.objectValue?["name"]?.stringValue == name && up.objectValue?["size"]?.doubleValue == 4)

    try api.request("POST", "/api/threads/\(tid)/send", ["text": "hello there", "files": [.string(name)]])
    check("while Claude works: busy, live activity, and the approval card for this thread",
          waitFor(10) { $0.busy.contains(tid) && $0.activity[tid] != nil && $0.currentPerms.count == 1 && $0.needsApproval(tid) })
    let perm = withState { $0.currentPerms.first }
    check("the approval is for a command, with its input", perm?.tool == "Bash" && perm?.input.objectValue?["command"] != nil)
    try api.request("POST", "/api/permissions/\(perm?.id ?? "")", ["allow": true])
    check("after approving: the card goes away and the turn finishes",
          waitFor(15) { !$0.busy.contains(tid) && $0.perms.isEmpty && $0.activity[tid] == nil })
    let saved = try api.request("GET", "/api/threads/\(tid)").objectValue?["messages"]?.arrayValue ?? []
    let live = withState { $0.current?.messages ?? [] }
    check("messages folded from live events equal what the server saved", !saved.isEmpty && live == saved)
    let msgs = withState { $0.messages }
    var shapes: [String] = []
    for m in msgs {
        switch m {
        case .user(let text, let files): shapes.append("user:\(text):\(files.map(\.name).joined()):\(files.first?.size ?? 0)")
        case .assistant(let blocks, let done):
            let tools = blocks.compactMap { b -> String? in if case .tool(let c) = b { return "\(c.name)/\(c.status)" }; return nil }
            let hasText = blocks.contains { if case .text(let x) = $0 { return !x.isEmpty }; return false }
            shapes.append("assistant:\(hasText):\(tools.joined(separator: ",")):\(done != nil)")
        case .system(let text): shapes.append("system:\(text)")
        case .compacted(let text): shapes.append("compacted:\(text)")
        }
    }
    check("typed messages: the user's text and file, then an answer with text, tool cards and a done line",
          shapes.first == "user:hello there:\(name):4" && shapes.count == 2
          && shapes[1].hasPrefix("assistant:true:Bash/ok") && shapes[1].hasSuffix(":true"))
    check("the event types the client saw", box.with { b in ["state", "busy", "activity", "perm", "perm_done", "thread"].allSatisfy(b.seen.contains) })

    check("each step keeps when it started (the work log shows the time)",
          withState { st in st.messages.contains { m in
              if case .assistant(let blocks, _) = m { return blocks.contains { b in if case .tool(let c) = b { return (c.at ?? 0) > 1_700_000_000_000 } else { return false } } }
              return false
          } })
    let sid = withState { $0.current?.thread.sessionId }
    try api.request("POST", "/api/threads/\(tid)/send", ["text": "/compact"])
    check("/compact: Claude Code's compaction leaves a note in the thread, and the session carries on",
          waitFor(10) { s in
              guard !s.busy.contains(tid), case .compacted(let text)? = s.messages.last else { return false }
              return text == "Conversation compacted (it was about 48k tokens). Claude continues from a summary of what came before."
                  && s.current?.thread.sessionId == sid && sid != nil
          })
    check("an automatic compaction says so",
          Reducer.compactNote(["trigger": "auto"]).hasPrefix("Conversation compacted automatically. ")
          && Reducer.compactNote(["trigger": "manual", "preTokens": 900]).contains("(it was 900 tokens)"))

    try api.request("PATCH", "/api/threads/\(tid)", ["title": "Renamed"])
    check("a rename reaches the open thread through the feed", waitFor(5) { $0.current?.thread.title == "Renamed" })
    try api.request("DELETE", "/api/threads/\(tid)")
    check("deleting the open thread closes it", waitFor(5) { $0.current == nil && $0.threads.isEmpty })

    stream.stop()
    let after = box.with { $0.connects }
    usleep(1_500_000)
    check("a stopped feed stays stopped", box.with { $0.connects } == after)
} catch {
    check("the native client's run against the server (threw: \(error))", false)
}

print("native client: what the screens show")
do {
    var s = ClientState()
    let e: (String, Double, Bool, Double, String?) -> JSONValue = { h, p, a, ts, note in
        var o: JSONObject = ["host": .string(h), "port": .number(p), "allowed": .bool(a), "ts": .number(ts)]
        if let n = note { o["note"] = .string(n) }
        return .object(o)
    }
    for ev in [e("api.anthropic.com", 443, true, 1, nil), e("evil.example", 443, false, 2, nil), e("api.anthropic.com", 443, true, 3, nil),
               e("pypi.org", 8443, false, 4, nil), e("plain.example", 80, false, 5, "plain http"), e("evil.example", 443, true, 0.5, nil)] {
        s.handle(["type": "net", "entry": ev])
    }
    let rows = s.networkRows
    check("network rows: grouped by host, port and outcome, newest first, counted",
          rows.map { "\($0.host):\($0.count):\($0.allowed)" } == ["plain.example:1:false", "pypi.org:1:false", "api.anthropic.com:2:true",
                                                                 "evil.example:1:false", "evil.example:1:true"]
          && s.blockedCount == 3 && rows[0].note == "plain http")
    check("'Allow' adds the host for 443, host:port otherwise", rows[1].allowEntry == "pypi.org:8443" && rows[3].allowEntry == "evil.example")
    s.handle(["type": "allow", "allow": ["api.anthropic.com", "pypi.org:8443"]])
    check("an 'allow' event updates the allow-list", s.allow == ["api.anthropic.com", "pypi.org:8443"])
    for i in 0..<510 { s.handle(["type": "net", "entry": e("h\(i)", 443, false, Double(10 + i), nil)]) }
    check("the network log keeps the last 500, the panel shows 100", s.netLog.count == 500 && s.networkRows.count == 100 && s.networkRows.first?.host == "h509")
    let permEv: JSONValue = ["type": "perm", "perm": ["id": "p1", "threadId": "t1", "tool": "Bash", "input": ["command": "ls"], "defaultToNo": true]]
    s.handle(permEv); s.handle(permEv)
    check("an approval request shows once, even if sent twice", s.perms.count == 1 && s.needsApproval("t1") && s.perms[0].defaultToNo && !s.needsApproval("t2"))
    s.handle(["type": "perm_done", "id": "p1"])
    check("'perm_done' removes the approval card", s.perms.isEmpty && !s.needsApproval("t1"))
    s.handle(["type": "busy", "threadId": "t1", "busy": true])
    s.handle(["type": "activity", "threadId": "t1", "activity": ["now": "Running a command", "since": 5, "steps": [["id": "a", "text": "Bash ls", "sub": false, "status": "ok"]]]])
    check("busy + activity", s.busy == ["t1"] && s.activity["t1"]?.steps.first?.status == "ok" && s.activity["t1"]?.now == "Running a command")
    s.handle(["type": "busy", "threadId": "t1", "busy": false])
    check("not busy any more: the activity goes", s.busy.isEmpty && s.activity["t1"] == nil)
    check("a 'state' event asks for a refresh", s.handle(["type": "state"]) == .refreshState && s.handle(["type": "nope"]) == .none)

    check("file sizes", ClientText.fileSize(1023) == "1023 B" && ClientText.fileSize(1536) == "1.5 KB" && ClientText.fileSize(3 * 1024 * 1024) == "3.0 MB")
    check("file icons", ClientText.fileIcon("A.JPEG") == "🖼" && ClientText.fileIcon("x.pdf") == "📕" && ClientText.fileIcon("notes.txt") == "📄")
    check("elapsed time", ClientText.elapsed(since: 0, now: 12_900) == "12s" && ClientText.elapsed(since: 0, now: 184_000) == "3m 4s" && ClientText.elapsed(since: 10, now: 0) == "0s")
    check("the done line", ClientText.doneLine(cost: 0.0042, turns: 2, ms: 1234) == "$0.0042 · 2 turns · 1.2s"
          && ClientText.doneLine(cost: 0, turns: 1, ms: nil) == "1 turn")
    check("first lines", ClientText.firstLines("a\nb\nc", 2) == "a\nb\n… (1 more lines)" && ClientText.firstLines("a\nb", 2) == "a\nb")
    check("mode hints", ClientText.modeHint("plan").hasPrefix("Read-only") && ClientText.modeHint("x") == "")
    check("tool titles in plain words: a command by Claude Code's description of it, files by name",
          toolTitle("Bash", ["command": "ls -la", "description": "List files in the project"]) == "List files in the project"
          && toolTitle("Bash", ["command": "ls -la"]) == "Ran a command"
          && toolTitle("Bash", ["command": "x", "description": "First line\nsecond"]) == "First line"
          && toolTitle("Read", ["file_path": "/a/b/Package.swift"]) == "Read Package.swift"
          && toolTitle("Edit", ["file_path": "/a/main.swift", "old_string": "x", "new_string": "y"]) == "Edited main.swift"
          && toolTitle("Write", [:]) == "Wrote a file"
          && toolTitle("Grep", ["pattern": "TODO", "path": "src"]) == "Searched for “TODO”"
          && toolTitle("Glob", ["pattern": "**/*.swift"]) == "Found files matching **/*.swift"
          && toolTitle("WebFetch", ["url": "https://docs.swift.org/x?y"]) == "Read docs.swift.org"
          && toolTitle("Task", ["description": "Look around"]) == "Agent: Look around"
          && toolTitle("SomeNewTool", ["query": "abc"]) == "SomeNewTool: abc" && toolTitle("SomeNewTool", nil) == "SomeNewTool")
    check("short mode names and model blurbs for the menus under the message box",
          ClientText.modeShort("commands") == "Auto commands" && ClientText.modeShort("ask") == "Ask first" && ClientText.modeShort("x") == "x"
          && ClientText.modelBlurb("claude-opus-5-5").hasPrefix("For complex") && !ClientText.modelBlurb("").isEmpty
          && ClientText.modelBlurb("claude-fable-5-2").hasPrefix("The most") && ClientText.modelBlurb("other") == "")
    // syntax colors in code blocks
    func kinds(_ code: String, _ lang: String) -> [String: SyntaxKind] {
        var m: [String: SyntaxKind] = [:]
        for t in Syntax.highlight(code, language: lang) where m[t.text] == nil { m[t.text] = t.kind }
        return m
    }
    func joins(_ code: String, _ lang: String) -> Bool { Syntax.highlight(code, language: lang).map(\.text).joined() == code }
    let samples: [(String, String)] = [
        ("js", "const x = 'a'; // hi\nlet re = /ab+c/gi, n = a / b;\nconsole.log(`t ${x}`, new Map(), this.default)\n/* end"),
        ("ts", "interface P { name: string; age?: number }\nexport const f = (p: P): void => {}"),
        ("json", "{\"a\": 1, \"b\": [true, null, \"x\"]}"),
        ("html", "<!DOCTYPE html>\n<a href=\"x\" data-y=z disabled>hi &amp; bye</a><!-- c -->\n<style>p { color: red; }</style><script>let a = 1 < 2</script><br/><img src='a'"),
        ("css", "@media (max-width: 600px) { .btn:hover, #main > a[href] { margin: 0 -4px; color: #fff !important; width: calc(100% - 2em) } }"),
        ("sql", "-- users\nCREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name VARCHAR(80) NOT NULL);\nSELECT u.name, COUNT(*) FROM users u WHERE u.id = $1 AND x::text = 'a''b' /* c"),
    ]
    check("syntax colors: every piece of code comes back exactly as it was, for each language",
          samples.allSatisfy { joins($0.1, $0.0) } && joins("x", "rust") && Syntax.highlight("", language: "js").isEmpty)
    var fuzzOK = true
    let alphabet = Array("ab<>/=\"'`\\{}();:.#@!&*-+ \n\t1é$[]%?")
    for _ in 0..<3000 {
        var code = ""
        for _ in 0..<Int.random(in: 0...40, using: &SeededRandom.shared) { code.append(alphabet.randomElement(using: &SeededRandom.shared)!) }
        for lang in ["js", "ts", "json", "html", "css", "sql"] where !joins(code, lang) { fuzzOK = false; print("    lost text:", lang, code.debugDescription) }
    }
    check("syntax colors: random fragments (unclosed strings, tags, comments…) come back exactly too", fuzzOK)
    let js = kinds("const x = 'a'; // hi\nfoo(1) + new Map(); let r = /ab+c/g; a / b; this.default", "js")
    check("JavaScript: keywords, names, strings, comments, calls, numbers, types, regexes, division",
          js["const"] == .keyword && js["x"] == .variable && js["'a'"] == .string && js["// hi"] == .comment
          && js["foo"] == .function && js["1"] == .number && js["Map"] == .type && js["/ab+c/g"] == .regexp
          && js["/"] == .operator && js["this"] == .special && js["default"] == .variable)
    let ts = kinds("let n: number = f() => 1", "ts")
    check("TypeScript: built-in types; => as a keyword", ts["number"] == .type && ts["=>"] == .keyword && kinds("let n: number", "js")["number"] == .variable)
    let json = kinds("{\"a\": 1, \"b\": true}", "json")
    check("JSON: keys, numbers, true / false / null", json["\"a\""] == .tag && json["1"] == .number && json["true"] == .operator)
    let html = kinds("<a href=\"x\">hi &amp; bye</a><style>p { color: red; }</style><script>let a = 1</script>", "html")
    check("HTML: tags, attributes, values, entities; the CSS and JavaScript inside <style> and <script>",
          html["a"] == .tag && html["href"] == .attribute && html["\"x\""] == .string && html["&amp;"] == .tag
          && html["p"] == .tag && html["color"] == .property && html["red"] == .value && html["let"] == .keyword && html["hi "] == .plain)
    let css = kinds(".btn:hover > a { margin: 0 4px; color: #fff !important; } @media screen {}", "css")
    check("CSS: selectors (class, pseudo, element), properties, values, numbers and units, colors, !important, at-rules",
          css[".btn"] == .attribute && css[":hover"] == .operator && css["a"] == .tag && css["margin"] == .property
          && css["4"] == .number && css["px"] == .tag && css["#fff"] == .operator && css["!important"] == .keyword
          && css["@media"] == .keyword && css["screen"] == .value)
    let sql = kinds("SELECT u.name, count(*) FROM users u WHERE id = :id AND deleted IS NULL; -- c\nCREATE TABLE t (n VARCHAR(80), d timestamp DEFAULT now())", "sql")
    check("SQL: keywords in any case, types, functions, parameters, NULL, comments; names stay plain",
          sql["SELECT"] == .keyword && sql["FROM"] == .keyword && sql["count"] == .function && sql[":id"] == .variable
          && sql["NULL"] == .number && sql["-- c"] == .comment && sql["VARCHAR"] == .type && sql["timestamp"] == .type
          && sql["DEFAULT"] == .keyword && sql["now"] == .function && sql[" users u "] == .plain && sql["name"] == .plain
          && kinds("INSERT INTO t (a) VALUES (1)", "sql")["t"] == nil && kinds("CREATE TABLE t (a int)", "sql")["t"] == nil
          && Syntax.language("PostgreSQL") == .sql)
    check("code in other languages stays plain", Syntax.highlight("fn main() {}", language: "rust") == [SyntaxToken(text: "fn main() {}", kind: .plain)])
    // the work log: "Worked for 5.3s", groups of steps
    func call(_ id: String, _ name: String) -> ChatBlock { .tool(ToolCall(id: id, name: name, input: [:], status: "ok", output: nil)) }
    let reply: [ChatBlock] = [.text("Let me look."), call("1", "Bash"), call("2", "Bash"), call("3", "Read"),
                              .text("Found it."), call("4", "Edit"), .text("Done: fixed the bug.")]
    let finished = ReplyLayout(reply)
    check("a reply: the steps and what Claude said between them fold away; the text after the last step is the answer",
          finished.work.count == 4 && finished.work[0] == .text("Let me look.") && finished.work[2] == .text("Found it.")
          && finished.answer == [.text("Done: fixed the bug.")])
    if case .group(let title, let calls)? = finished.work.dropFirst().first {
        check("steps in a row are one group with a summary; a lone step is its own row",
              title == "Ran 2 commands, read a file" && calls.map(\.id) == ["1", "2", "3"] && finished.work[3].isStep && !finished.work[2].isStep)
    } else {
        check("steps in a row are one group with a summary; a lone step is its own row", false)
    }
    check("a reply with no tools has nothing to fold; one still running folds what it did so far",
          ReplyLayout([.text("hi")]).work.isEmpty && ReplyLayout([.text("hi")]).answer == [.text("hi")]
          && ReplyLayout(Array(reply.prefix(3))).work.count == 2 && ReplyLayout(Array(reply.prefix(3))).answer.isEmpty)
    check("group summaries and the Worked-for header",
          ClientText.toolsSummary(["Grep", "Glob", "WebSearch", "Write", "Mystery"]) == "Searched the code 2 times, searched the web, edited a file, used a tool"
          && ClientText.workedFor(5300) == "Worked for 5.3s" && ClientText.workedFor(134_000) == "Worked for 2m 14s"
          && ClientText.workedFor(nil) == "Worked")
    check("menu descriptions wrap at spaces",
          ClientText.wrap("aaa bbb ccc", width: 7) == "aaa bbb\nccc" && ClientText.wrap("abcdefghij k", width: 4) == "abcdefghij\nk"
          && ClientText.wrap("", width: 5) == "" && ClientText.wrap(ClientText.modeHint("commands"), width: 44).split(separator: "\n").allSatisfy { $0.count <= 44 })
    check("long titles are cut to one line", toolTitle("Bash", ["description": .string(String(repeating: "a", count: 300))]).count == 120)
}

// MARK: - the server end to end (was test/smoke.mjs)

/// One HTTP request to a loopback port, as any program on the Mac (or a web page) could send it.
func httpRequest(_ port: Int, _ method: String, _ path: String, host: String? = nil, headers: [(String, String)] = [],
                 body: [UInt8] = []) -> (status: Int, headers: [String: String], body: String) {
    guard let fd = Net.connect(host: "127.0.0.1", port: port) else { return (0, [:], "") }
    defer { _ = close(fd) }
    Net.setReceiveTimeout(fd, 30)
    var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    guard Net.sendAll(fd, Array(head.utf8) + body) else { return (0, [:], "") }
    var got: [UInt8] = []
    while let chunk = Net.receive(fd) { got += chunk }
    guard let end = Net.find([13, 10, 13, 10], in: got) else { return (0, [:], "") }
    let lines = String(decoding: got[..<end], as: UTF8.self).components(separatedBy: "\r\n")
    var hs: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let colon = l.firstIndex(of: ":") else { continue }
        hs[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return (Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0, hs, String(decoding: got[(end + 4)...], as: UTF8.self))
}

func waitFor<T>(_ seconds: Double = 6, _ probe: () -> T?) -> T? {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let v = probe() { return v }
        usleep(40_000)
    }
    return nil
}

func posixMode(_ path: String) -> Int { ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

print("the server end to end (mock mode): security gates")
do {
    let tmp = URL(fileURLWithPath: realPath(tempDir().deletingLastPathComponent())).appendingPathComponent("charness-e2e-\(UUID().uuidString)")
    temps.append(tmp)
    let proj = tmp.appendingPathComponent("proj").path
    try fm.createDirectory(atPath: proj, withIntermediateDirectories: true)
    let echo = try Net.serve { s in _ = Net.sendAll(s, Array("hello-from-echo".utf8)); Net.finish(s) }
    defer { echo.stop() }
    var cfg = ServerConfig(environment: ["HARNESS_ALLOW_HOSTS": "127.0.0.1:\(echo.port)"])
    cfg.home = tmp.appendingPathComponent("home"); cfg.port = 0; cfg.mock = true
    let server = try CharnessServer(config: cfg)
    try server.start()
    defer { server.stop() }
    let port = server.port, base = "http://127.0.0.1:\(port)"

    check("no cookie → 401", httpRequest(port, "GET", "/api/state").status == 401)
    check("wrong Host header (DNS rebinding) → 403", httpRequest(port, "GET", "/api/state", host: "evil.com:\(port)").status == 403)
    check("bad token → 401", httpRequest(port, "GET", "/?token=nope").status == 401)
    let login = httpRequest(port, "GET", "/?token=\(server.token)")
    let setCookie = login.headers["set-cookie"] ?? ""
    check("good token → strict HttpOnly cookie", login.status == 204 && setCookie.contains("HttpOnly; SameSite=Strict"))
    let cookie = String(setCookie.split(separator: ";").first ?? "")
    let jsonHeaders = [("Cookie", cookie), ("X-Harness", "1"), ("Origin", base), ("Content-Type", "application/json")]
    func call(_ method: String, _ path: String, _ body: JSONValue? = nil, headers: [(String, String)]? = nil) -> (status: Int, json: JSONValue) {
        let r = httpRequest(port, method, path, headers: headers ?? jsonHeaders, body: body.map { Array($0.jsonString().utf8) } ?? [])
        return (r.status, (try? JSONValue.parse(r.body)) ?? .null)
    }
    check("POST with foreign Origin → 403", call("POST", "/api/projects", ["path": .string(proj)],
                                                 headers: [("Cookie", cookie), ("X-Harness", "1"), ("Origin", "http://evil.com")]).status == 403)
    check("POST without X-Harness header → 403", call("POST", "/api/projects", ["path": .string(proj)],
                                                       headers: [("Cookie", cookie), ("Origin", base)]).status == 403)
    let page = httpRequest(port, "GET", "/", headers: [("Cookie", cookie)])
    check("no web pages are served; replies carry a strict CSP and nosniff",
          page.status == 404 && httpRequest(port, "GET", "/app.js", headers: [("Cookie", cookie)]).status == 404
          && page.headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'none'"
          && page.headers["x-content-type-options"] == "nosniff")

    // the live-event feed, as the app gets it
    let frames = LineLog()
    let feedClient = APIClient(port: port)
    try feedClient.login(token: server.token)
    let feed = EventStream(client: feedClient, onEvent: { ev in if let o = ev.objectValue { frames.add(o) } }, onConnection: { _ in })
    feed.start()
    defer { feed.stop() }

    print("the server end to end: threads & permissions")
    func state() -> JSONObject { call("GET", "/api/state").json.objectValue ?? JSONObject() }
    func thread(_ id: String) -> JSONObject { call("GET", "/api/threads/\(id)").json.objectValue ?? JSONObject() }
    func firstPerm(_ threadId: String? = nil) -> JSONObject? {
        (state()["perms"]?.arrayValue ?? []).compactMap(\.objectValue).first { threadId == nil || $0["threadId"]?.stringValue == threadId }
    }
    func idle(_ id: String, atLeast n: Int) -> JSONObject? {
        let r = thread(id)
        return r["thread"]?.objectValue?["busy"] != true && (r["messages"]?.arrayValue?.count ?? 0) >= n ? r : nil
    }
    func messages(_ r: JSONObject?) -> [JSONObject] { (r?["messages"]?.arrayValue ?? []).compactMap(\.objectValue) }
    func blocks(_ m: JSONObject?) -> [JSONObject] { (m?["blocks"]?.arrayValue ?? []).compactMap(\.objectValue) }

    check("rejects non-folder", call("POST", "/api/projects", ["path": .string(tmp.appendingPathComponent("missing").path)]).status == 400)
    let p = call("POST", "/api/projects", ["path": .string(proj)]).json.text("id")
    let t = call("POST", "/api/threads", ["projectId": .string(p)]).json.text("id")
    _ = call("PATCH", "/api/threads/\(t)", ["mode": "ask"])
    check("a message is accepted (202)", call("POST", "/api/threads/\(t)/send", ["text": "hello there"]).status == 202)
    let perm = waitFor { firstPerm() }
    check("Bash permission request raised", perm?["tool"] == "Bash")
    let live = thread(t)["activity"]?.objectValue
    check("live activity: \"waiting for approval\" with the step running",
          live?["now"]?.stringValue?.hasPrefix("Waiting for your approval: Bash") == true
          && (live?["steps"]?.arrayValue ?? []).contains { $0.objectValue?["text"] == "Bash: ls -la" && $0.objectValue?["status"] == "running" })
    check("approving answers 200", call("POST", "/api/permissions/\(perm?["id"]?.stringValue ?? "")", ["allow": true]).status == 200)
    let done = waitFor(10) { idle(t, atLeast: 2) }
    let asst = messages(done).first { $0["role"] == "assistant" }
    let tool = blocks(asst).first { $0["type"] == "tool" }
    check("streamed text + approved tool + result + cost recorded",
          blocks(asst).contains { $0["type"] == "text" && ($0["text"]?.stringValue ?? "").contains("Mock mode") }
          && tool?["status"] == "ok" && (tool?["output"]?.stringValue ?? "").contains("hello.txt")
          && (asst?["done"]?.objectValue?["cost"]?.doubleValue ?? 0) > 0)
    check("thread auto-titled", done?["thread"]?.objectValue?["title"] == "hello there")
    _ = waitFor { frames.all.contains { $0["type"] == "busy" && $0["threadId"]?.stringValue == t && $0["busy"] == false } ? true : nil }
    let acts = frames.all.filter { $0["type"] == "activity" && $0["threadId"]?.stringValue == t }.compactMap { $0["activity"]?.objectValue }
    let nows = Set(acts.compactMap { $0["now"]?.stringValue })
    check("live activity: thinking, writing, the running command, sub-agent steps",
          ["Thinking…", "Writing…", "Bash: ls -la", "↳ Glob: **/*"].allSatisfy(nows.contains))
    let lastSteps = (acts.last?["steps"]?.arrayValue ?? []).compactMap(\.objectValue).map {
        "\($0["sub"] == true ? "↳ " : "")\($0["text"]?.stringValue ?? "") \($0["status"]?.stringValue ?? "")"
    }
    check("live activity: steps ticked off, cleared when done, sub-agent steps not saved",
          acts.last?["now"] == .null
          && lastSteps == ["Bash: ls -la ok", "Task: Look around the project ok", "↳ Glob: **/* ok", "↳ Read: \(proj)/hello.txt ok"]
          && thread(t)["activity"] == .null && !JSONValue.array((done?["messages"]?.arrayValue ?? [])).jsonString().contains("**/*"))

    _ = call("POST", "/api/threads/\(t)/send", ["text": "edit something"])
    let perm2 = waitFor { firstPerm() }
    _ = call("POST", "/api/permissions/\(perm2?["id"]?.stringValue ?? "")", ["allow": false])
    let done2 = waitFor(10) { idle(t, atLeast: 4) }
    check("denied tool is marked denied and Claude is told",
          perm2?["tool"] == "Edit" && blocks(messages(done2).last).first { $0["type"] == "tool" }?["status"] == "denied")

    _ = call("PATCH", "/api/threads/\(t)", ["mode": "plan"])
    check("\"full access\" mode is refused unless explicitly enabled", call("PATCH", "/api/threads/\(t)", ["mode": "full"]).status == 400)

    _ = call("PATCH", "/api/threads/\(t)", ["mode": "commands"])
    let permsBefore = frames.all.filter { $0["type"] == "perm" }.count
    let before = messages(thread(t)).count
    _ = call("POST", "/api/threads/\(t)/send", ["text": "hello there"])
    let doneCmd = waitFor(10) { idle(t, atLeast: before + 2) }
    check("\"auto-accept edits & commands\": a command runs without asking",
          blocks(messages(doneCmd).last).first { $0["type"] == "tool" }?["status"] == "ok"
          && frames.all.filter { $0["type"] == "perm" }.count == permsBefore)
    _ = call("POST", "/api/threads/\(t)/send", ["text": "edit something"])
    let permCmd = waitFor { firstPerm() }
    check("… while other tools still ask", permCmd?["tool"] == "Edit")
    _ = call("POST", "/api/permissions/\(permCmd?["id"]?.stringValue ?? "")", ["allow": false])
    _ = waitFor(10) { idle(t, atLeast: 0) }

    _ = call("PATCH", "/api/threads/\(t)", ["mode": "ask"])
    _ = call("POST", "/api/threads/\(t)/send", ["text": "stop me"])
    _ = waitFor { firstPerm() }
    _ = call("POST", "/api/threads/\(t)/stop")
    _ = waitFor(10) { idle(t, atLeast: 0) }
    check("stop cancels run and clears pending prompt", (state()["perms"]?.arrayValue ?? [1]).isEmpty)

    usleep(700_000)
    let home = tmp.appendingPathComponent("home").path
    check("thread saved to disk, files are chmod 600",
          ((try? fm.contentsOfDirectory(atPath: home + "/threads")) ?? []).contains("\(t).json") && posixMode(home + "/state.json") == 0o600)

    print("the server end to end: attachments")
    let t2 = call("POST", "/api/threads", ["projectId": .string(p)]).json.text("id")
    _ = call("PATCH", "/api/threads/\(t2)", ["mode": "ask"])
    func upload(_ name: String, _ bytes: [UInt8], origin: String? = nil) -> (status: Int, json: JSONValue) {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? name
        let r = httpRequest(port, "POST", "/api/threads/\(t2)/files", headers: [("Cookie", cookie), ("X-Harness", "1"), ("Origin", origin ?? base),
                                                                               ("Content-Type", "application/octet-stream"), ("X-File-Name", enc)], body: bytes)
        return (r.status, (try? JSONValue.parse(r.body)) ?? .null)
    }
    let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52]
    let up1 = upload("notes.txt", Array("hello from a file".utf8)).json
    check("files upload (text and binary, duplicate names numbered)",
          up1 == ["name": "notes.txt", "size": 17] && upload("notes.txt", Array("again".utf8)).json.text("name") == "notes (2).txt"
          && upload("foto ñ.png", png).json == ["name": "foto ñ.png", "size": .number(Double(png.count))])
    let updir = home + "/uploads/" + t2
    check("names cleaned (no ../, no hidden files), folder 700, files 600",
          upload("../../../evil.txt", [120]).json.text("name") == "evil.txt" && upload(".env", [120]).json.text("name") == "env"
          && ((try? fm.contentsOfDirectory(atPath: updir)) ?? []).sorted() == ["env", "evil.txt", "foto ñ.png", "notes (2).txt", "notes.txt"]
          && posixMode(updir) == 0o700 && posixMode(updir + "/notes.txt") == 0o600)
    check("foreign origin, files over 25 MB and unknown or ../ names refused",
          upload("x.txt", [120], origin: "http://evil.com").status == 403
          && upload("big.bin", [UInt8](repeating: 0, count: 25 * 1024 * 1024 + 1)).status == 413
          && call("POST", "/api/threads/\(t2)/send", ["text": "hi", "files": ["../state.json"]]).status == 400
          && call("POST", "/api/threads/\(t2)/send", ["text": "hi", "files": ["missing.txt"]]).status == 400)
    let sentFiles = call("POST", "/api/threads/\(t2)/send", ["text": "", "files": ["notes.txt", "foto ñ.png"]]).status
    let perm3 = waitFor { firstPerm(t2) }
    _ = call("POST", "/api/permissions/\(perm3?["id"]?.stringValue ?? "")", ["allow": true])
    let done3 = waitFor(10) { idle(t2, atLeast: 2) }
    let first = messages(done3).first
    let expected: JSONValue = ["role": "user", "text": "", "files": [["name": "notes.txt", "size": 17], ["name": "foto ñ.png", "size": .number(Double(png.count))]],
                               "ts": first?["ts"] ?? .null]
    check("a message with only files is sent; files saved with it; thread named after the file",
          sentFiles == 202 && first.map(JSONValue.object) == expected && done3?["thread"]?.objectValue?["title"] == "notes.txt"
          && (blocks(messages(done3).dropFirst().first).first?["text"]?.stringValue ?? "").contains("Attached files"))
    check("deleting the thread deletes its files", call("DELETE", "/api/threads/\(t2)").status == 200 && !fm.fileExists(atPath: updir))

    print("the server end to end: git (hardened)")
    check("non-repo handled", call("GET", "/api/threads/\(t)/diff").json.objectValue?["isRepo"] == false)

    print("the server end to end: egress guard")
    check("the guard is on", state()["guard"]?.objectValue?["on"] == true && server.guardPort != nil)
    func tunnel(_ host: String, _ p: Int) -> String {
        guard let gp = server.guardPort, let s = Net.connect(host: "127.0.0.1", port: gp) else { return "" }
        defer { _ = close(s) }
        Net.setReceiveTimeout(s, 2)
        _ = Net.sendAll(s, Array("CONNECT \(host):\(p) HTTP/1.1\r\nHost: \(host):\(p)\r\n\r\n".utf8))
        var got = "", poked = false
        while let chunk = Net.receive(s) {
            got += String(decoding: chunk, as: UTF8.self)
            if !poked && got.contains("\r\n\r\n") && got.hasPrefix("HTTP/1.1 200") { poked = true; _ = Net.sendAll(s, [120]) }
        }
        return got
    }
    check("unlisted host refused", tunnel("telemetry.example.com", 443).contains("403"))
    check("allowed host on wrong port refused", tunnel("api.anthropic.com", 8443).contains("403"))
    let through = tunnel("127.0.0.1", echo.port)
    check("allow-listed host tunnels through", through.hasPrefix("HTTP/1.1 200 Connection Established") && through.contains("hello-from-echo"))
    check("blocked attempt is logged", (state()["guard"]?.objectValue?["log"]?.arrayValue ?? []).contains {
        $0.objectValue?["host"] == "telemetry.example.com" && $0.objectValue?["allowed"] != true })
    check("the app can add a host to the allow-list", call("POST", "/api/net/allow", ["host": "telemetry.example.com"]).status == 200
          && (state()["guard"]?.objectValue?["allow"]?.arrayValue ?? []).contains("telemetry.example.com"))
} catch {
    check("the server end to end (threw: \(error))", false)
}

// MARK: - Markdown (native screens)

print("Markdown gives the same structure the web UI's md.js did")
do {
    /// [tag, {attrs}, ...kids] as md.js's DOM was recorded (adjacent text merged, empty text dropped)
    func el(_ tag: String, _ attrs: JSONObject = JSONObject(), _ kids: [JSONValue]) -> JSONValue {
        var out: [JSONValue] = [.string(tag), .object(attrs)]
        for k in kids {
            if case .string(let s) = k {
                if s.isEmpty { continue }
                if out.count > 2, case .string(let prev) = out[out.count - 1] { out[out.count - 1] = .string(prev + s); continue }
            }
            out.append(k)
        }
        return .array(out)
    }
    func inl(_ xs: [MDInline]) -> [JSONValue] {
        xs.map { x -> JSONValue in
            switch x {
            case .text(let s): return .string(s)
            case .code(let s): return el("code", ["class": "ic"], [.string(s)])
            case .strong(let k): return el("strong", JSONObject(), inl(k))
            case .em(let k): return el("em", JSONObject(), inl(k))
            case .del(let k): return el("del", JSONObject(), inl(k))
            case .link(let u, let k): return el("a", ["href": .string(u), "target": "_blank", "rel": "noopener noreferrer nofollow"], inl(k))
            }
        }
    }
    func list(_ l: MDList) -> JSONValue {
        el(l.ordered ? "ol" : "ul", JSONObject(), l.items.map { el("li", JSONObject(), inl($0.text) + $0.lists.map(list)) })
    }
    func blocks(_ bs: [MDBlock]) -> JSONValue {
        el("div", ["class": "md"], bs.map { b -> JSONValue in
            switch b {
            case .heading(let level, let t): return el("h\(level)", JSONObject(), inl(t))
            case .paragraph(let lines):
                var kids: [JSONValue] = []
                for (k, l) in lines.enumerated() { if k > 0 { kids.append(el("br", JSONObject(), [])) }; kids += inl(l) }
                return el("p", JSONObject(), kids)
            case .code(let lang, let text):
                return el("div", ["class": "code"], [
                    el("div", ["class": "codehead"], [el("span", JSONObject(), [.string(lang.isEmpty ? "text" : lang)]), el("button", ["class": "copy"], ["Copy"])]),
                    el("pre", JSONObject(), [el("code", JSONObject(), [.string(text)])])])
            case .quote(let inner): return el("blockquote", JSONObject(), [blocks(inner)])
            case .list(let l): return list(l)
            case .table(let head, let rows):
                return el("div", ["class": "tablewrap"], [el("table", JSONObject(), [
                    el("thead", JSONObject(), [el("tr", JSONObject(), head.map { el("th", JSONObject(), inl($0)) })]),
                    el("tbody", JSONObject(), rows.map { r in el("tr", JSONObject(), r.map { el("td", JSONObject(), inl($0)) }) })])])
            case .rule: return el("hr", JSONObject(), [])
            }
        })
    }
    let samples = (try JSONValue.parse(Array(Data(contentsOf: fixtures.appendingPathComponent("markdown.json"))))).arrayValue ?? []
    var bad: [String] = []
    for sm in samples {
        let o = sm.objectValue ?? JSONObject()
        let src = o["src"]?.stringValue ?? ""
        let got = o["plain"] == true ? el("pre", JSONObject(), inl(Markdown.linkify(src))) : blocks(Markdown.parse(src))
        if got != o["tree"] { bad.append(o["name"]?.stringValue ?? "?"); print("      \(o["name"]!.stringValue!):\n        md.js \(o["tree"]!.jsonString())\n        Swift \(got.jsonString())") }
    }
    check("all \(samples.count) samples match md.js\(bad.isEmpty ? "" : " (not: \(bad.joined(separator: ", ")))")", samples.count >= 30 && bad.isEmpty)

    // beyond md.js, as T3 Code (GitHub-flavored Markdown) shows replies
    func firstList(_ src: String) -> MDList? {
        if case .list(let l)? = Markdown.parse(src).first { return l }
        return nil
    }
    let started = firstList("3. three\n4. four\n   1. nested one")
    check("ordered lists keep their first number (nested ones too); unordered ones start at 1",
          started?.start == 3 && started?.items.count == 2 && started?.items[1].lists.first?.start == 1
          && firstList("7) seven")?.start == 7 && firstList("- a")?.start == 1 && firstList("10. ten")?.start == 10)
    let tasks = firstList("- [ ] todo\n- [x] done\n- [X] also done\n- [] not a task\n- plain")
    check("task lists: [ ] and [x] become unchecked / checked items, the brackets dropped",
          tasks?.items.map(\.task) == [false, true, true, nil, nil]
          && tasks?.items.map(\.text) == [[.text("todo")], [.text("done")], [.text("also done")], [.text("[] not a task")], [.text("plain")]])
    check("_underscores_ are italic at word edges only (snake_case_names stay as they are)",
          Markdown.inline("an _easy_ one") == [.text("an "), .em([.text("easy")]), .text(" one")]
          && Markdown.inline("snake_case_name and file_a_b") == [.text("snake_case_name and file_a_b")]
          && Markdown.inline("x_y_ z") == [.text("x_y_ z")]
          && Markdown.inline("__bold__ and _ spaced _") == [.strong([.text("bold")]), .text(" and _ spaced _")]
          && Markdown.inline("(_note_)") == [.text("("), .em([.text("note")]), .text(")")])
} catch {
    check("Markdown samples (threw: \(error))", false)
}

// MARK: - login shell PATH (Charness.app)

print("the app takes PATH from the login shell")
do {
    check("PATH is read between the markers, whatever start-up files print",
          ShellPath.parse("Welcome!\n__CHARNESS_PATH_START__/opt/homebrew/bin:/usr/bin__CHARNESS_PATH_END__\nbye") == "/opt/homebrew/bin:/usr/bin"
          && ShellPath.parse("no markers") == nil && ShellPath.parse("__CHARNESS_PATH_START____CHARNESS_PATH_END__") == nil)
    check("merged: the shell's entries first, then missing current ones, no duplicates or empty entries",
          ShellPath.merge(shell: "/opt/homebrew/bin:/usr/bin::/bin", current: "/usr/bin:/bin:/usr/sbin:/sbin")
            == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          && ShellPath.merge(shell: nil, current: "/usr/bin") == "/usr/bin")
    let dir = tempDir()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func script(_ name: String, _ body: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        _ = chmod(path, 0o755)
        return path
    }
    // a "shell" that chats on start-up, then runs the -c command it was given (as zsh -i -l -c would)
    let chatty = try script("chatty", "echo 'Last login: today'\n[ \"$1 $2 $3\" = '-i -l -c' ] || exit 9\nPATH=/fake/bin:/usr/bin\neval \"$4\"\necho done")
    check("the -c command prints the shell's PATH (with start-up noise around it)", ShellPath.fromLoginShell(chatty) == "/fake/bin:/usr/bin")
    let t0 = Date()
    let hang = try script("hang", "sleep 30")
    check("a shell that hangs is given up on in time", ShellPath.fromLoginShell(hang, timeout: 1) == nil && Date().timeIntervalSince(t0) < 3)
    check("a failing shell gives nothing", ShellPath.fromLoginShell(try script("fail", "echo __CHARNESS_PATH_START__/x__CHARNESS_PATH_END__; exit 1")) == nil)
    check("only an absolute path to a program is run", ShellPath.fromLoginShell("sh") == nil && ShellPath.fromLoginShell(dir.path + "/missing") == nil)
    if fm.isExecutableFile(atPath: "/bin/bash") {
        let real = ShellPath.fromLoginShell("/bin/bash", environment: ["HOME": dir.path, "PATH": "/usr/bin:/bin"])
        check("a real login shell answers", real?.split(separator: ":").contains { $0 == "/usr/bin" || $0 == "/bin" } == true)
    }
} catch {
    check("login shell PATH (threw: \(error))", false)
}

for t in temps { try? fm.removeItem(at: t) }
print(failed == 0 ? "\nall \(passed) checks passed" : "\n\(failed) of \(passed + failed) checks FAILED")
exit(failed == 0 ? 0 : 1)


/// A repeatable random number generator (SplitMix64), so a failing random check fails the same way every run.
struct SeededRandom: RandomNumberGenerator {
    nonisolated(unsafe) static var shared = SeededRandom(seed: 42)
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
