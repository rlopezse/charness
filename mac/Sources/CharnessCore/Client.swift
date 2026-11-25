// The client side of the native screens: talks to the Charness server over loopback exactly as the web UI
// (public/app.js) does — token -> cookie, X-Harness header, Origin — so the native screens go through every check
// the server makes, and keeps the same screen state app.js keeps. Foundation only, so it is tested on Linux
// against a real server in mock mode (`swift run core-checks`); the SwiftUI views just draw ClientState.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct APIError: Error, CustomStringConvertible {
    public let status: Int
    public let message: String
    public var description: String { message }
    public init(status: Int, message: String) { self.status = status; self.message = message }
}

/// A small HTTP client for the server's /api (one request per connection, like the server answers).
public final class APIClient: @unchecked Sendable {
    public let port: Int
    private let lock = NSLock()
    private var cookie = ""

    public init(port: Int) { self.port = port }

    var host: String { "127.0.0.1:\(port)" }
    var cookieHeader: String { lock.lock(); defer { lock.unlock() }; return cookie }

    /// Trades the access token for the session cookie (the first visit to /?token=… in a browser).
    public func login(token: String) throws {
        let enc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? token
        let r = try raw("GET", "/?token=\(enc)", headers: [], body: [])
        guard r.status == 302, let set = r.headers["set-cookie"], let pair = set.split(separator: ";").first else {
            throw APIError(status: r.status, message: "The server refused the access token.")
        }
        lock.lock(); cookie = String(pair); lock.unlock()
    }

    /// A JSON API call. Throws APIError with the server's message (as app.js's api() does) when it fails.
    @discardableResult
    public func request(_ method: String, _ path: String, _ body: JSONValue? = nil) throws -> JSONValue {
        var headers: [(String, String)] = []
        var bytes: [UInt8] = []
        if let b = body {
            headers.append(("Content-Type", "application/json"))
            bytes = Array(b.jsonString().utf8)
        }
        return try decode(raw(method, path, headers: headers, body: bytes))
    }

    /// Uploads one attached file (POST /api/threads/:id/files). Returns {name, size}.
    public func upload(threadId: String, name: String, bytes: [UInt8]) throws -> JSONValue {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? name
        let r = try raw("POST", "/api/threads/\(threadId)/files",
                        headers: [("Content-Type", "application/octet-stream"), ("X-File-Name", encoded)], body: bytes)
        do { return try decode(r) } catch let e as APIError { throw APIError(status: e.status, message: "\(name): \(e.message)") }
    }

    private func decode(_ r: (status: Int, headers: [String: String], body: [UInt8])) throws -> JSONValue {
        let value = (try? JSONValue.parse(r.body)) ?? .null
        guard (200..<300).contains(r.status) else {
            throw APIError(status: r.status, message: value.objectValue?["error"]?.stringValue ?? HTTPResponse.reason(r.status))
        }
        return value
    }

    func raw(_ method: String, _ path: String, headers: [(String, String)], body: [UInt8]) throws -> (status: Int, headers: [String: String], body: [UInt8]) {
        guard let fd = Net.connect(host: "127.0.0.1", port: port) else {
            throw APIError(status: 0, message: "Can't reach the Charness server on port \(port).")
        }
        defer { _ = close(fd) }
        Net.setReceiveTimeout(fd, 120)   // an upload of 25 MB is quick on loopback; never hang the app for ever
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nX-Harness: 1\r\n"
        if method != "GET" && method != "HEAD" { head += "Origin: http://\(host)\r\n" }
        let c = cookieHeader
        if !c.isEmpty { head += "Cookie: \(c)\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard Net.sendAll(fd, Array(head.utf8) + body) else { throw APIError(status: 0, message: "The connection to the server broke.") }
        var got: [UInt8] = []
        while let chunk = Net.receive(fd) { got += chunk }   // the server closes after answering
        guard let end = Net.find([13, 10, 13, 10], in: got) else { throw APIError(status: 0, message: "No answer from the server.") }
        let lines = String(decoding: got[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        var hs: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            hs[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var bodyBytes = Array(got[(end + 4)...])
        if let n = hs["content-length"].flatMap(Int.init), n < bodyBytes.count { bodyBytes = Array(bodyBytes[..<n]) }
        return (status, hs, bodyBytes)
    }
}

/// The live-event feed (GET /api/events, Server-Sent Events), reconnecting on its own like EventSource.
public final class EventStream: @unchecked Sendable {
    private let client: APIClient
    private let onEvent: @Sendable (JSONValue) -> Void
    private let onConnection: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var fd: Int32 = -1

    /// onEvent gets each event's JSON; onConnection(true) each time the feed (re)connects, false when it drops.
    /// Both are called on a background thread.
    public init(client: APIClient, onEvent: @escaping @Sendable (JSONValue) -> Void, onConnection: @escaping @Sendable (Bool) -> Void) {
        self.client = client
        self.onEvent = onEvent
        self.onConnection = onConnection
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while !isStopped {
                runOnce()
                if isStopped { break }
                onConnection(false)
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    public func stop() {
        lock.lock(); stopped = true; let f = fd; lock.unlock()
        if f >= 0 { _ = shutdown(f, Int32(SHUT_RDWR)) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func runOnce() {
        guard let s = Net.connect(host: "127.0.0.1", port: client.port) else { return }
        lock.lock(); fd = s; let stop = stopped; lock.unlock()
        defer { lock.lock(); fd = -1; lock.unlock(); _ = close(s) }
        if stop { return }
        Net.setReceiveTimeout(s, 45)     // the server pings every 20 s; silence for longer means it is gone
        let req = "GET /api/events HTTP/1.1\r\nHost: \(client.host)\r\nCookie: \(client.cookieHeader)\r\nAccept: text/event-stream\r\n\r\n"
        guard Net.sendAll(s, Array(req.utf8)) else { return }

        var buf: [UInt8] = []
        var headerDone = false
        var text: [UInt8] = []          // the de-chunked event text
        while let chunk = Net.receive(s) {
            buf += chunk
            if !headerDone {
                guard let end = Net.find([13, 10, 13, 10], in: buf) else { continue }
                let status = String(decoding: buf[..<end], as: UTF8.self).split(separator: " ").dropFirst().first
                guard status == "200" else { return }
                headerDone = true
                buf.removeFirst(end + 4)
                onConnection(true)
            }
            // chunked transfer: "<hex size>\r\n<data>\r\n" ...
            while let nl = Net.find([13, 10], in: buf) {
                guard let size = Int(String(decoding: buf[..<nl], as: UTF8.self).split(separator: ";").first ?? "", radix: 16) else { return }
                if size == 0 { return }
                guard buf.count >= nl + 2 + size + 2 else { break }
                text += buf[(nl + 2)..<(nl + 2 + size)]
                buf.removeFirst(nl + 2 + size + 2)
            }
            // events are separated by a blank line; only "data: …" lines matter (": ping" is a keep-alive)
            while let sep = Net.find([10, 10], in: text) {
                let frame = String(decoding: text[..<sep], as: UTF8.self)
                text.removeFirst(sep + 2)
                for line in frame.split(separator: "\n") where line.hasPrefix("data: ") {
                    if let v = try? JSONValue.parse(String(line.dropFirst(6))) { onEvent(v) }
                }
            }
        }
    }
}

// MARK: - what the screens show

/// One message of a thread, typed for drawing (the saved form is the JSON public/reduce.js builds).
public enum ChatMessage {
    case user(text: String, files: [(name: String, size: Int)])
    case assistant(blocks: [ChatBlock], done: (cost: Double?, turns: Double?, ms: Double?)?)
    case system(text: String)

    public init(_ v: JSONValue) {
        let m = v.objectValue ?? JSONObject()
        switch m["role"]?.stringValue {
        case "user":
            let files = (m["files"]?.arrayValue ?? []).compactMap { f -> (name: String, size: Int)? in
                guard let o = f.objectValue else { return nil }
                return (JS.string(o["name"]), Int(o["size"]?.doubleValue ?? 0))
            }
            self = .user(text: JS.string(m["text"]), files: files)
        case "assistant":
            let blocks = (m["blocks"]?.arrayValue ?? []).compactMap { b -> ChatBlock? in
                guard let o = b.objectValue else { return nil }
                if o["type"] == "text" { return .text(JS.string(o["text"])) }
                if o["type"] == "tool" {
                    return .tool(ToolCall(id: JS.string(o["id"]), name: JS.string(o["name"]), input: o["input"] ?? .object(JSONObject()),
                                          status: JS.string(o["status"]), output: o["output"]?.stringValue))
                }
                return nil
            }
            let d = m["done"]?.objectValue
            self = .assistant(blocks: blocks, done: d.map { ($0["cost"]?.doubleValue, $0["turns"]?.doubleValue, $0["ms"]?.doubleValue) })
        default:
            self = .system(text: JS.string(m["text"]))
        }
    }
}

public enum ChatBlock: Equatable {
    case text(String)
    case tool(ToolCall)
}

public struct ToolCall: Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let status: String   // running | ok | error | denied
    public let output: String?
    /// A field of the input as text, the way the web UI prints it (`i.command ?? ''`).
    public func field(_ key: String) -> String { JS.string(input.objectValue?[key]) }
    /// The one-line summary shown on the card (toolSummary()).
    public var summary: String { toolSummary(name, input) }
}

/// A permission prompt waiting for the user (the server's `perm` objects).
public struct PendingPermission: Equatable {
    public let raw: JSONObject
    public var id: String { JS.string(raw["id"]) }
    public var threadId: String { JS.string(raw["threadId"]) }
    public var tool: String { JS.string(raw["tool"]) }
    public var input: JSONValue { raw["input"] ?? .object(JSONObject()) }
    public var title: String? { raw["title"]?.stringValue }
    public var description: String? { raw["description"]?.stringValue }
    public var defaultToNo: Bool { raw["defaultToNo"] == true }
}

/// One line of the Network panel (attempts to the same host:port and outcome are counted together).
public struct NetworkRow: Equatable {
    public let host: String
    public let port: Double
    public let allowed: Bool
    public let note: String?
    public let count: Int
    public let ts: Double
    /// "host:port" as the panel shows it.
    public var target: String { "\(host):\(JSONValue.jsNumber(port))" }
    /// What "Allow" adds to the allow-list: just the host for 443, host:port otherwise.
    public var allowEntry: String { port == 443 ? host : "\(host):\(JSONValue.jsNumber(port))" }
}

/// A choice in a menu (models, permission modes).
public struct Option: Hashable {
    public let id: String
    public let label: String
}

/// Everything the screens show, kept the way public/app.js keeps its state `S`.
public struct ClientState {
    public var projects: [Project] = []
    public var threads: [ChatThread] = []
    public var models: [Option] = []
    public var modes: [Option] = []
    public var mock = false
    public var guardOn = false
    public var allow: [String] = []
    public var netLog: [JSONObject] = []
    public var perms: [PendingPermission] = []
    public var busy = Set<String>()
    public var activity: [String: Activity] = [:]
    public var current: (thread: ChatThread, messages: [JSONValue])?
    public var connected = false

    public init() {}

    /// What handle() wants done next (app.js does these right away).
    public enum FollowUp: Equatable { case none, refreshState }

    /// GET /api/state (refreshState() in app.js).
    public mutating func applyState(_ v: JSONValue) {
        let o = v.objectValue ?? JSONObject()
        projects = (o["projects"]?.arrayValue ?? []).compactMap { $0.objectValue.map(Project.init(raw:)) }
        threads = (o["threads"]?.arrayValue ?? []).compactMap { $0.objectValue.map(ChatThread.init(raw:)) }
        models = ClientState.options(o["models"])
        modes = ClientState.options(o["modes"])
        mock = o["mock"] == true
        let g = o["guard"]?.objectValue
        guardOn = g?["on"] == true
        allow = g?["allow"]?.arrayValue?.compactMap(\.stringValue) ?? []
        netLog = g?["log"]?.arrayValue?.compactMap(\.objectValue) ?? []
        perms = (o["perms"]?.arrayValue ?? []).compactMap { $0.objectValue.map(PendingPermission.init(raw:)) }
        busy = Set(threads.filter { $0.raw["busy"] == true }.map(\.id))
        for id in activity.keys where !busy.contains(id) { activity[id] = nil }
        if let cur = current {
            if let t = threads.first(where: { $0.id == cur.thread.id }) { current = (t, cur.messages) } else { current = nil }
        }
    }

    /// GET /api/threads/:id (openThread() in app.js).
    public mutating func applyThread(_ v: JSONValue) {
        let o = v.objectValue ?? JSONObject()
        guard let t = o["thread"]?.objectValue.map(ChatThread.init(raw:)) else { return }
        current = (t, o["messages"]?.arrayValue ?? [])
        if let a = o["activity"].flatMap(Activity.init(json:)) { activity[t.id] = a } else { activity[t.id] = nil }
    }

    /// One live event (handleEvent() in app.js). Returns what to do next.
    @discardableResult
    public mutating func handle(_ event: JSONValue) -> FollowUp {
        let e = event.objectValue ?? JSONObject()
        let threadId = JS.string(e["threadId"])
        switch e["type"]?.stringValue {
        case "state":
            return .refreshState
        case "busy":
            if e["busy"] == true { busy.insert(threadId) } else { busy.remove(threadId); activity[threadId] = nil }
        case "activity":
            activity[threadId] = e["activity"].flatMap(Activity.init(json:))
        case "perm":
            if let p = e["perm"]?.objectValue.map(PendingPermission.init(raw:)) {
                if let i = perms.firstIndex(where: { $0.id == p.id }) { perms[i] = p } else { perms.append(p) }
            }
        case "perm_done":
            perms.removeAll { $0.id == JS.string(e["id"]) }
        case "thread":
            if var cur = current, cur.thread.id == threadId, let ev = e["ev"] {
                current = nil                           // let go of the messages so they change in place
                Reducer.apply(&cur.messages, ev)
                current = cur
            }
        case "net":
            if let entry = e["entry"]?.objectValue {
                netLog.append(entry)
                if netLog.count > 500 { netLog.removeFirst() }
            }
        case "allow":
            allow = e["allow"]?.arrayValue?.compactMap(\.stringValue) ?? allow
        default:
            break
        }
        return .none
    }

    // MARK: derived, for drawing

    public var messages: [ChatMessage] { current?.messages.map(ChatMessage.init) ?? [] }

    /// Threads of a project, most recently updated first.
    public func threads(of projectId: String) -> [ChatThread] {
        threads.filter { $0.projectId == projectId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func needsApproval(_ threadId: String) -> Bool { perms.contains { $0.threadId == threadId } }

    public var currentPerms: [PendingPermission] {
        guard let id = current?.thread.id else { return [] }
        return perms.filter { $0.threadId == id }
    }

    public var blockedCount: Int { netLog.filter { $0["allowed"] != true }.count }

    /// The Network panel's rows: attempts grouped by host, port and outcome, newest first, at most 100.
    public var networkRows: [NetworkRow] {
        var order: [String] = []
        var groups: [String: NetworkRow] = [:]
        for e in netLog {
            let host = JS.string(e["host"]), port = e["port"]?.doubleValue ?? 0, allowed = e["allowed"] == true
            let key = "\(host):\(port)|\(allowed)"
            let n = (groups[key]?.count ?? 0) + 1
            if groups[key] == nil { order.append(key) }
            groups[key] = NetworkRow(host: host, port: port, allowed: allowed, note: e["note"]?.stringValue ?? groups[key]?.note,
                                     count: n, ts: e["ts"]?.doubleValue ?? 0)
        }
        return order.compactMap { groups[$0] }.sorted { $0.ts > $1.ts }.prefix(100).map { $0 }
    }

    static func options(_ v: JSONValue?) -> [Option] {
        (v?.arrayValue ?? []).compactMap { $0.objectValue }.map { Option(id: JS.string($0["id"]), label: JS.string($0["label"])) }
    }
}

public enum ClientText {
    /// The hint under the message box for each mode (MODE_HINT in app.js).
    public static func modeHint(_ mode: String) -> String {
        switch mode {
        case "ask": return "Claude asks before editing files or running commands."
        case "edits": return "File edits are applied automatically; commands still ask."
        case "commands": return "File edits and shell commands run without asking; other tools still ask."
        case "plan": return "Read-only: Claude explores and proposes a plan, changes nothing."
        case "full": return "No prompts at all. Only use in a throwaway folder or VM."
        default: return ""
        }
    }

    public static func fileSize(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    public static func fileIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(where: { lower.hasSuffix(".\($0)") }) { return "🖼" }
        if lower.hasSuffix(".pdf") { return "📕" }
        return "📄"
    }

    /// "12s", "3m 4s" since a time in ms.
    public static func elapsed(since: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let sec = max(0, Int((now - since) / 1000))
        return sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s"
    }

    /// "$0.0042 · 2 turns · 1.2s" under a finished answer.
    public static func doneLine(cost: Double?, turns: Double?, ms: Double?) -> String {
        var bits: [String] = []
        if let c = cost, c != 0 { bits.append(String(format: "$%.4f", c)) }
        if let t = turns, t != 0 { bits.append("\(Int(t)) turn\(t > 1 ? "s" : "")") }
        if let m = ms, m != 0 { bits.append(String(format: "%.1fs", m / 1000)) }
        return bits.joined(separator: " · ")
    }

    /// The first `n` lines, then "… (k more lines)".
    public static func firstLines(_ s: String, _ n: Int) -> String {
        let a = s.components(separatedBy: "\n")
        return a.count > n ? a.prefix(n).joined(separator: "\n") + "\n… (\(a.count - n) more lines)" : s
    }
}

extension Activity {
    /// From the server's JSON ({now, since, steps}).
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        let steps = (o["steps"]?.arrayValue ?? []).compactMap { s -> ActivityStep? in
            guard let x = s.objectValue else { return nil }
            return ActivityStep(id: JS.string(x["id"]), text: JS.string(x["text"]), sub: x["sub"] == true, status: JS.string(x["status"]))
        }
        self.init(now: o["now"]?.stringValue, since: o["since"]?.doubleValue ?? 0, steps: steps)
    }
}

extension JSONValue {
    /// A field of an object as the web UI prints it (`o.key ?? ''`): "" when missing or null.
    public func text(_ key: String) -> String { JS.string(objectValue?[key]) }
}
