// Read-only check of your real Charness data against the Swift store.
//     swift run --package-path mac charness-check            # HARNESS_HOME or ~/.charness
//     swift run --package-path mac charness-check /some/dir
// It never creates, writes or deletes anything, and never prints chat contents: only counts, file names,
// permissions and whether Swift would rewrite each file exactly as Node wrote it.

import Foundation
import CharnessCore

let args = CommandLine.arguments.dropFirst()
if args.contains("-h") || args.contains("--help") {
    print("usage: charness-check [DATA_DIR]   (default: HARNESS_HOME or ~/.charness)")
    exit(0)
}
let home = args.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Store.defaultHome()
let fm = FileManager.default
var problems = 0
var notes = 0

func ok(_ s: String) { print("  ✓ \(s)") }
func bad(_ s: String) { problems += 1; print("  ✗ \(s)") }
func note(_ s: String) { notes += 1; print("  • \(s)") }
func octal(_ m: Int?) -> String { m.map { "0" + String($0, radix: 8) } ?? "missing" }

print("Charness data: \(home.path)")
guard fm.fileExists(atPath: home.path) else {
    print("  Nothing there yet (the folder doesn't exist). Start the app once, then run this again.")
    exit(0)
}

let store: Store
do {
    store = try Store(home: home, readOnly: true)
} catch {
    bad("the Swift store can't open it: \(error)")
    exit(1)
}

let state = store.state
print("  \(state.projects.count) project(s), \(state.threads.count) thread(s), \(state.allowHosts.count) extra allowed host(s)")

// state.json
let stateURL = store.stateURL
if let original = try? Data(contentsOf: stateURL) {
    let rewritten = Data(Store.stateFileText(state).utf8)
    if rewritten == original {
        ok("state.json: Swift rewrites it byte for byte")
    } else {
        let at = zip(rewritten, original).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
            ?? min(rewritten.count, original.count)
        bad("state.json: Swift would write it differently (first difference at byte \(at))")
    }
} else {
    note("state.json doesn't exist yet")
}

// thread files
var identical = 0, missing = 0
for t in state.threads {
    let url = store.threadsURL.appendingPathComponent("\(t.id).json")
    guard Store.isValidId(t.id) else { bad("thread with an invalid id in state.json: \(t.id.debugDescription)"); continue }
    guard let original = try? Data(contentsOf: url) else { missing += 1; continue }
    do {
        let file = try store.thread(t.id)
        if Data(Store.threadFileText(file).utf8) == original { identical += 1 }
        else { bad("threads/\(t.id).json: Swift would write it differently") }
    } catch {
        bad("threads/\(t.id).json: \(error)")
    }
}
if identical > 0 { ok("\(identical) thread file(s): Swift rewrites them byte for byte") }
if missing > 0 { note("\(missing) thread(s) have no messages file yet (normal for threads with no messages saved)") }

// files nobody references (e.g. left by a crash); reported only, never removed
let known = Set(state.threads.map { "\($0.id).json" })
let listed = (try? fm.contentsOfDirectory(atPath: store.threadsURL.path)) ?? []
let extra = listed.filter { !known.contains($0) }.sorted()
if !extra.isEmpty { note("\(extra.count) file(s) in threads/ not referenced by state.json: \(extra.prefix(5).joined(separator: ", "))\(extra.count > 5 ? ", …" : "")") }

// permissions (chats can contain sensitive code)
let folderModes = [home, store.threadsURL].map { ($0, StoreFiles.mode($0)) }
for (url, m) in folderModes where m != nil && m != 0o700 { bad("\(url.path) has mode \(octal(m)), expected 0700") }
var loose: [String] = []
for name in ["state.json", "token"] where fm.fileExists(atPath: home.appendingPathComponent(name).path) {
    if StoreFiles.mode(home.appendingPathComponent(name)) != 0o600 { loose.append(name) }
}
for name in listed where name.hasSuffix(".json") {
    if StoreFiles.mode(store.threadsURL.appendingPathComponent(name)) != 0o600 { loose.append("threads/\(name)") }
}
if loose.isEmpty { ok("permissions: folders 0700, files 0600") }
else { bad("\(loose.count) file(s) readable by others than you (expected 0600): \(loose.prefix(5).joined(separator: ", "))") }

print(problems == 0 ? "\nAll good. Nothing was changed." : "\n\(problems) problem(s) found. Nothing was changed.")
exit(problems == 0 ? 0 : 1)
