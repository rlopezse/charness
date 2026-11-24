// Swift port of lib/store.mjs: JSON persistence under ~/.charness (override: HARNESS_HOME).
//
// Same files, same layout, same permissions (dirs 0700, files 0600, atomic replace), same debounced writes
// (state 200 ms, messages 400 ms). Files are rewritten byte for byte as Node writes them, and fields this
// code doesn't know about are kept, so Node and Swift can take turns on the same data during the migration.
//
// Two deliberate differences from the Node version:
//  * A state.json or thread file that exists but isn't valid JSON is an error here. Node quietly starts
//    from empty data and then overwrites the file on its next save; refusing is safer.
//  * Thread ids are checked (lowercase hex) before they become file names, in the store itself.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - records

/// A project: a folder Claude works in. `raw` keeps every field, including ones added later.
public struct Project: Equatable {
    public var raw: JSONObject

    public init(raw: JSONObject) { self.raw = raw }
    public init(id: String, name: String, path: String) {
        raw = ["id": .string(id), "name": .string(name), "path": .string(path)]
    }

    public var id: String { get { raw["id"]?.stringValue ?? "" } set { raw["id"] = .string(newValue) } }
    public var name: String { get { raw["name"]?.stringValue ?? "" } set { raw["name"] = .string(newValue) } }
    public var path: String { get { raw["path"]?.stringValue ?? "" } set { raw["path"] = .string(newValue) } }
}

/// A chat thread's settings and totals (its messages live in threads/<id>.json). Named ChatThread to keep
/// clear of Foundation's Thread.
public struct ChatThread: Equatable {
    public var raw: JSONObject

    public init(raw: JSONObject) { self.raw = raw }
    /// Same fields, in the same order, as the server's POST /api/threads.
    public init(id: String, projectId: String, title: String, model: String, mode: String, now: Double) {
        raw = [
            "id": .string(id), "projectId": .string(projectId), "title": .string(title),
            "model": .string(model), "mode": .string(mode), "sessionId": .null, "cost": 0,
            "createdAt": .number(now), "updatedAt": .number(now),
        ]
    }

    public var id: String { get { raw["id"]?.stringValue ?? "" } set { raw["id"] = .string(newValue) } }
    public var projectId: String { get { raw["projectId"]?.stringValue ?? "" } set { raw["projectId"] = .string(newValue) } }
    public var title: String { get { raw["title"]?.stringValue ?? "" } set { raw["title"] = .string(newValue) } }
    public var model: String { get { raw["model"]?.stringValue ?? "" } set { raw["model"] = .string(newValue) } }
    public var mode: String { get { raw["mode"]?.stringValue ?? "" } set { raw["mode"] = .string(newValue) } }
    public var sessionId: String? {
        get { raw["sessionId"]?.stringValue }
        set { raw["sessionId"] = newValue.map(JSONValue.string) ?? .null }
    }
    public var cost: Double { get { raw["cost"]?.doubleValue ?? 0 } set { raw["cost"] = .number(newValue) } }
    /// Milliseconds since 1970, like JavaScript's Date.now().
    public var createdAt: Double { get { raw["createdAt"]?.doubleValue ?? 0 } set { raw["createdAt"] = .number(newValue) } }
    public var updatedAt: Double { get { raw["updatedAt"]?.doubleValue ?? 0 } set { raw["updatedAt"] = .number(newValue) } }
}

/// Everything in state.json.
public struct AppState: Equatable {
    public var raw: JSONObject

    public init() { raw = ["projects": [], "threads": [], "allowHosts": []] }
    /// Like the Node version: Object.assign({projects: [], threads: [], allowHosts: []}, contentsOfStateJson).
    public init(fileObject: JSONObject) {
        self.init()
        for (k, v) in fileObject.entries { raw[k] = v }
    }

    public var projects: [Project] {
        get { raw["projects"]?.arrayValue?.compactMap { $0.objectValue.map(Project.init(raw:)) } ?? [] }
        set { raw["projects"] = .array(newValue.map { .object($0.raw) }) }
    }
    public var threads: [ChatThread] {
        get { raw["threads"]?.arrayValue?.compactMap { $0.objectValue.map(ChatThread.init(raw:)) } ?? [] }
        set { raw["threads"] = .array(newValue.map { .object($0.raw) }) }
    }
    public var allowHosts: [String] {
        get { raw["allowHosts"]?.arrayValue?.compactMap { $0.stringValue } ?? [] }
        set { raw["allowHosts"] = .array(newValue.map(JSONValue.string)) }
    }
}

/// The contents of threads/<id>.json. Messages stay plain JSON until the reducer is ported.
public struct ThreadFile: Equatable {
    public var raw: JSONObject

    public init() { raw = ["messages": []] }
    public init(raw: JSONObject) { self.raw = raw }

    public var messages: [JSONValue] {
        get { raw["messages"]?.arrayValue ?? [] }
        set { raw["messages"] = .array(newValue) }
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case readOnly
    case badThreadId(String)
    case io(path: String, operation: String, code: Int32)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): return "\(path) can't be read: \(reason). It was left untouched."
        case .readOnly: return "this store was opened read-only"
        case .badThreadId(let id): return "not a valid thread id: \(id.debugDescription)"
        case .io(let path, let op, let code): return "\(op) \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - store

/// Thread-safe: every method may be called from any thread. Don't call the store from inside an
/// update closure (it would wait for itself).
public final class Store: @unchecked Sendable {   // all mutable fields are only touched on `queue`
    public let home: URL
    public let readOnly: Bool
    public var stateURL: URL { home.appendingPathComponent("state.json") }
    public var threadsURL: URL { home.appendingPathComponent("threads", isDirectory: true) }

    private let stateDelay: Double
    private let messagesDelay: Double
    private let queue = DispatchQueue(label: "charness.store")
    private var current: AppState
    private var cache: [String: ThreadFile] = [:]
    private var dirty = Set<String>()        // thread ids whose messages need writing
    private var stateDue = false
    private var messagesDue = false
    private var writeError: Error?

    /// HARNESS_HOME if set, else ~/.charness (same rule as the Node server).
    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["HARNESS_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".charness", isDirectory: true)
    }

    /// Opens (and, unless read-only, creates) the data folder and reads state.json.
    /// A read-only store never creates, writes or deletes anything.
    public init(home: URL = Store.defaultHome(), readOnly: Bool = false,
                stateDelay: Double = 0.2, messagesDelay: Double = 0.4) throws {
        self.home = home
        self.readOnly = readOnly
        self.stateDelay = stateDelay
        self.messagesDelay = messagesDelay
        if !readOnly { try Files.makeDirectories(home.appendingPathComponent("threads", isDirectory: true)) }
        let stateFile = home.appendingPathComponent("state.json")
        current = try Files.readObject(stateFile).map(AppState.init(fileObject:)) ?? AppState()
    }

    /// 12 random lowercase hex characters, like the Node version's newId().
    public static func newId() -> String {
        let hex = Array("0123456789abcdef")
        var rng = SystemRandomNumberGenerator()
        var s = ""
        for _ in 0..<6 {
            let byte = UInt8.random(in: 0...255, using: &rng)
            s.append(hex[Int(byte >> 4)])
            s.append(hex[Int(byte & 0xF)])
        }
        return s
    }

    /// Thread ids become file names, so only lowercase hex is accepted (the same pattern the server's routes use).
    public static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    // MARK: state

    public var state: AppState { queue.sync { current } }

    /// Changes the state and schedules a write (debounced, like saveState()).
    @discardableResult
    public func updateState<T>(_ change: (inout AppState) throws -> T) throws -> T {
        guard !readOnly else { throw StoreError.readOnly }
        return try queue.sync {
            let result = try change(&current)
            if !stateDue {
                stateDue = true
                queue.asyncAfter(deadline: .now() + stateDelay) { [weak self] in self?.flushStateNow(timer: true) }
            }
            return result
        }
    }

    // MARK: threads

    /// The thread's messages file; empty if it doesn't exist yet (like loadThread()).
    public func thread(_ id: String) throws -> ThreadFile {
        try queue.sync { try load(id) }
    }

    /// Changes a thread's messages and schedules a write (debounced, like saveMessages()).
    @discardableResult
    public func updateThread<T>(_ id: String, _ change: (inout ThreadFile) throws -> T) throws -> T {
        guard !readOnly else { throw StoreError.readOnly }
        return try queue.sync {
            var file = try load(id)
            let result = try change(&file)
            cache[id] = file
            dirty.insert(id)
            if !messagesDue {
                messagesDue = true
                queue.asyncAfter(deadline: .now() + messagesDelay) { [weak self] in self?.flushMessagesNow(timer: true) }
            }
            return result
        }
    }

    /// Forgets the thread and deletes its file (like deleteThreadFiles()). Missing files are fine.
    public func deleteThreadFiles(_ id: String) throws {
        guard !readOnly else { throw StoreError.readOnly }
        guard Store.isValidId(id) else { throw StoreError.badThreadId(id) }
        queue.sync {
            cache[id] = nil
            dirty.remove(id)
            _ = unlink(threadURL(id).path)
        }
    }

    // MARK: writing

    /// Writes everything that is pending now (like flushAll(), called on quit).
    public func flushAll() throws {
        if readOnly { return }
        try queue.sync {
            var first: Error?
            if stateDue { do { try writeState() } catch { first = error } }
            if messagesDue || !dirty.isEmpty { do { try writeMessages() } catch { first = first ?? error } }
            if let e = first { throw e }
        }
    }

    /// The last error from a debounced (timer) write, if any. flushAll() throws its own errors directly.
    public var lastWriteError: Error? { queue.sync { writeError } }

    /// state.json exactly as the Node server writes it: JSON.stringify(state, null, 2), no trailing newline.
    public static func stateFileText(_ state: AppState) -> String { JSONValue.object(state.raw).jsonString(pretty: true) }
    /// threads/<id>.json exactly as the Node server writes it: JSON.stringify(thread).
    public static func threadFileText(_ file: ThreadFile) -> String { JSONValue.object(file.raw).jsonString() }

    // MARK: private (only on `queue`)

    private func threadURL(_ id: String) -> URL { threadsURL.appendingPathComponent("\(id).json") }

    private func load(_ id: String) throws -> ThreadFile {
        guard Store.isValidId(id) else { throw StoreError.badThreadId(id) }
        if let cached = cache[id] { return cached }
        let file = try Files.readObject(threadURL(id)).map(ThreadFile.init(raw:)) ?? ThreadFile()
        cache[id] = file
        return file
    }

    private func flushStateNow(timer: Bool) {
        guard stateDue else { return }   // flushAll() already wrote it
        do { try writeState() } catch { writeError = error }
    }

    private func flushMessagesNow(timer: Bool) {
        guard messagesDue else { return }
        do { try writeMessages() } catch { writeError = error }
    }

    private func writeState() throws {
        stateDue = false
        try Files.writeAtomically(Store.stateFileText(current), to: stateURL)
    }

    private func writeMessages() throws {
        messagesDue = false
        var first: Error?
        for id in dirty.sorted() {
            guard let file = cache[id] else { dirty.remove(id); continue }
            do {
                try Files.writeAtomically(Store.threadFileText(file), to: threadURL(id))
                dirty.remove(id)
            } catch {
                first = first ?? error   // stays dirty, so the next flush tries again
            }
        }
        if let e = first { throw e }
    }
}

// MARK: - files

enum Files {
    /// nil if the file doesn't exist; throws if it exists but isn't a JSON object.
    static func readObject(_ url: URL) throws -> JSONObject? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw StoreError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch {
            throw StoreError.unreadable(path: url.path, reason: "\(error)")
        }
        guard case .object(let obj) = value else {
            throw StoreError.unreadable(path: url.path, reason: "expected a JSON object")
        }
        return obj
    }

    /// mkdir -p with mode 0700 for every folder it creates (like fs.mkdirSync(..., {recursive: true, mode: 0o700})).
    static func makeDirectories(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw StoreError.io(path: url.path, operation: "mkdir", code: ENOTDIR)
        }
        try makeDirectories(url.deletingLastPathComponent())
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            throw StoreError.io(path: url.path, operation: "mkdir", code: errno)
        }
    }

    /// Writes "<file>.<pid>.tmp" with mode 0600, then renames it over the file (like writeAtomic()).
    static func writeAtomically(_ text: String, to url: URL) throws {
        let path = url.path
        let tmp = "\(path).\(getpid()).tmp"
        _ = unlink(tmp)   // a leftover from a crash
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { throw StoreError.io(path: tmp, operation: "open", code: errno) }
        let bytes = Array(text.utf8)
        var failure: Int32 = 0
        var offset = 0
        bytes.withUnsafeBytes { buf in
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if close(fd) != 0 && failure == 0 { failure = errno }
        if failure == 0 && rename(tmp, path) != 0 { failure = errno }
        if failure != 0 {
            _ = unlink(tmp)
            throw StoreError.io(path: path, operation: "write", code: failure)
        }
    }

    /// The permission bits of a file or folder, e.g. 0o600; nil if it doesn't exist.
    static func mode(_ url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.posixPermissions] as? NSNumber else { return nil }
        return n.intValue & 0o777
    }
}

/// Small helpers the checks and the check tool share.
public enum StoreFiles {
    public static func mode(_ url: URL) -> Int? { Files.mode(url) }
}
