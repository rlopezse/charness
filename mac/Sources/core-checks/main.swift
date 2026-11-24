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

for t in temps { try? fm.removeItem(at: t) }
print(failed == 0 ? "\nall \(passed) checks passed" : "\n\(failed) of \(passed + failed) checks FAILED")
exit(failed == 0 ? 0 : 1)
