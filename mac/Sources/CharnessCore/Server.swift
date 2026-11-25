// Swift port of server.mjs: the Charness server. Same /api, same auth (token -> strict HttpOnly cookie, Host
// and Origin checks, X-Harness header), same security headers and live-event feed, same files on disk, so the
// unchanged web UI in public/ runs on it. Built from the other ports: Store (lib/store.mjs), ClaudeTurn and
// MockClaude (lib/agent.mjs), Reducer (public/reduce.js), EgressGuard (lib/guard.mjs), Uploads
// (lib/uploads.mjs). test/smoke.mjs runs against it with CHARNESS_SERVER=<charness-server binary>.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ServerConfig {
    /// The repository folder: the UI is read from public/, the bundled claude binary from node_modules/.
    public var root: URL
    public var home: URL
    public var port = 4317
    public var mock = false
    public var guardOn = true
    public var rotateToken = false
    /// The environment the server works from (the child's is an allow-listed slice of it).
    public var environment: [String: String]
    /// The claude binary; nil = HARNESS_CLAUDE_BIN, else the one bundled with the Agent SDK, else `claude` on PATH.
    public var claudeExecutable: String?

    public init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        self.environment = environment
        self.home = Store.defaultHome(environment: environment)
        if let p = environment["PORT"], let n = Int(p) { port = n }
        mock = environment["HARNESS_MOCK"] == "1"
        guardOn = environment["HARNESS_NET_GUARD"] != "off"
    }
}

public final class CharnessServer: @unchecked Sendable {
    public let config: ServerConfig
    public let store: Store
    public let uploads: Uploads
    public private(set) var token = ""
    public private(set) var port = 0
    public var guardPort: Int? { egress?.port }
    public var link: String { "http://127.0.0.1:\(port)/?token=\(token)" }

    private struct Mode { let id: String; let label: String; let sdk: String }
    private let models: [JSONValue] = [
        ["id": "", "label": "Default"],
        ["id": "claude-opus-5-5", "label": "Opus 5.5"],
        ["id": "claude-sonnet-5-5", "label": "Sonnet 5.5"],
        ["id": "claude-haiku-5-5", "label": "Haiku 5.5"],
        ["id": "claude-fable-5-2", "label": "Fable 5.2"],
    ]
    private let modes: [Mode]

    private final class Run {
        let turn: ClaudeTurn
        var activity: JSONValue = .null
        init(_ turn: ClaudeTurn) { self.turn = turn }
    }
    private struct Pending {
        let perm: JSONObject
        let input: JSONValue
        let requestId: String
        let answer: (PermissionDecision) -> Void
    }

    // everything below is only touched on `q`
    private let q = DispatchQueue(label: "charness.server")
    private var http: HTTPServer?
    private var egress: EgressGuard?
    private var pinger: DispatchSourceTimer?
    private var staticFiles: [String: (type: String, body: [UInt8])] = [:]
    private var clients: [HTTPResponse] = []
    private var netLog: [JSONValue] = []
    private var runs: [String: Run] = [:]
    private var pendingOrder: [String] = []
    private var pending: [String: Pending] = [:]

    static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("X-Frame-Options", "DENY"),
    ]
    static let denied = "The user denied this action. Do not retry it; ask what they would like instead."

    public init(config: ServerConfig) throws {
        self.config = config
        store = try Store(home: config.home)
        uploads = Uploads(home: config.home)
        var m = [Mode(id: "ask", label: "Ask before changes", sdk: "default"),
                 Mode(id: "edits", label: "Auto-accept edits", sdk: "acceptEdits"),
                 Mode(id: "plan", label: "Plan only", sdk: "plan")]
        if config.environment["HARNESS_ALLOW_FULL_ACCESS"] == "1" {
            m.append(Mode(id: "full", label: "Full access (no prompts)", sdk: "bypassPermissions"))
        }
        modes = m
        for (url, file, type) in [("/", "index.html", "text/html; charset=utf-8"), ("/app.js", "app.js", "text/javascript; charset=utf-8"),
                                  ("/md.js", "md.js", "text/javascript; charset=utf-8"), ("/reduce.js", "reduce.js", "text/javascript; charset=utf-8"),
                                  ("/style.css", "style.css", "text/css; charset=utf-8")] {
            let path = config.root.appendingPathComponent("public/\(file)")
            guard let data = FileManager.default.contents(atPath: path.path) else {
                throw StoreError.unreadable(path: path.path, reason: "the web UI file is missing")
            }
            staticFiles[url] = (type, Array(data))
        }
        token = try loadToken()
    }

    // MARK: start / stop

    /// Starts the egress guard (unless off) and the HTTP server. Throws if the port is busy.
    public func start() throws {
        if config.guardOn {
            let env = config.environment
            let upstream = [env["HARNESS_UPSTREAM_PROXY"], env["HTTPS_PROXY"], env["https_proxy"]].compactMap { $0 }.first { !$0.isEmpty }
            let g = EgressGuard(allowList: { [unowned self] in allowList() }, upstream: upstream) { [weak self] entry in
                self?.logNet(entry)
            }
            try g.start()
            egress = g
        }
        let server = HTTPServer(maxBody: Uploads.maxFileBytes) { [unowned self] req, res in handle(req, res) }
        do { try server.start(port: config.port) } catch {
            egress?.stop()
            throw error
        }
        http = server
        port = server.port
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.writeAll(": ping\n\n") }
        timer.resume()
        pinger = timer
    }

    /// Stops every run, the guard and the HTTP server, and writes what is pending to disk.
    public func stop() {
        let turns: [ClaudeTurn] = q.sync {
            pinger?.cancel()
            return runs.values.map(\.turn)
        }
        for t in turns { t.stop() }
        http?.stop()
        egress?.stop()
        try? store.flushAll()
    }

    // MARK: auth

    private func loadToken() throws -> String {
        let file = config.home.appendingPathComponent("token")
        if !config.rotateToken, let t = (try? String(contentsOf: file, encoding: .utf8))?.trimmingJSSpace(), t.utf16.count >= 32 {
            return t
        }
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let t = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try Files.writeAtomically("\(t)\n", to: file)
        return t
    }

    /// Constant-time comparison with the token (the time taken doesn't depend on where they differ).
    private func tokenOk(_ s: String?) -> Bool {
        guard let s = s, !s.isEmpty else { return false }
        let a = Array(s.utf8), b = Array(token.utf8)
        var diff = a.count ^ b.count
        for i in 0..<max(a.count, b.count) { diff |= Int((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)) }
        return diff == 0
    }

    private func cookie(_ req: HTTPRequest, _ name: String) -> String? {
        for part in (req.headers["cookie"] ?? "").split(separator: ";") {
            guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { continue }
            if part[..<eq].trimmingCharacters(in: .whitespaces) == name { return part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: helpers (on q)

    /// The hosts Claude may reach through the guard right now.
    public func allowedHosts() -> [String] { allowList() }

    private func allowList() -> [String] {
        var list = ["api.anthropic.com"]
        if let base = config.environment["ANTHROPIC_BASE_URL"], let u = URLComponents(string: base), let h = u.host, !h.isEmpty {
            let defaultPort = (u.scheme == "https" && u.port == 443) || (u.scheme == "http" && u.port == 80)
            list.append(u.port != nil && !defaultPort ? "\(h.lowercased()):\(u.port!)" : h.lowercased())
        }
        list += (config.environment["HARNESS_ALLOW_HOSTS"] ?? "").split(separator: ",").map { String($0).trimmingJSSpace() }.filter { !$0.isEmpty }
        list += store.state.allowHosts
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private func logNet(_ entry: GuardLogEntry) {
        q.sync {
            netLog.append(entry.json)
            if netLog.count > 500 { netLog.removeFirst() }
            broadcast(["type": "net", "entry": entry.json])
        }
    }

    private func broadcast(_ obj: JSONValue) { writeAll("data: \(obj.jsonString())\n\n") }

    private func writeAll(_ text: String) {
        clients.removeAll { !$0.write(text) }
    }

    private func publicThread(_ t: ChatThread) -> JSONValue {
        var o = t.raw
        o["busy"] = .bool(runs[t.id] != nil)
        return .object(o)
    }

    private func pendingFor(_ threadId: String) -> [JSONValue] {
        pendingOrder.compactMap { pending[$0] }.filter { $0.perm["threadId"]?.stringValue == threadId }.map { .object($0.perm) }
    }

    /// Answers a pending prompt. The answer runs off `q` (it can report activity, which needs `q`).
    @discardableResult
    private func settle(_ permId: String, _ decision: PermissionDecision) -> Bool {
        guard let p = pending.removeValue(forKey: permId) else { return false }
        pendingOrder.removeAll { $0 == permId }
        DispatchQueue.global().async { p.answer(decision) }
        broadcast(["type": "perm_done", "id": .string(permId)])
        return true
    }

    private func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

    // MARK: runs

    /// Folds one event into the thread, saves, and sends it to the browser (emit() in sendMessage()).
    private func emit(_ threadId: String, _ ev: JSONValue) {
        var e = ev.objectValue ?? JSONObject()
        if e["ts"] == nil || e["ts"] == .null { e["ts"] = .number(nowMs()) }
        let event = JSONValue.object(e)
        _ = try? store.updateThread(threadId) { $0.apply(event) }
        _ = try? store.updateState { s in
            var threads = s.threads
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            if e["t"] == "session" { threads[i].raw["sessionId"] = e["sessionId"] }
            if e["t"] == "end" { threads[i].cost = threads[i].cost + (e["cost"]?.doubleValue ?? 0) }
            threads[i].updatedAt = nowMs()
            s.threads = threads
        }
        broadcast(["type": "thread", "threadId": .string(threadId), "ev": event])
    }

    private func claudeExecutable() -> String? {
        if let c = config.claudeExecutable { return c }
        if let c = config.environment["HARNESS_CLAUDE_BIN"], !c.isEmpty { return c }
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #if os(macOS)
        let os = "darwin"
        #else
        let os = "linux"
        #endif
        let arch = machine == "x86_64" ? "x64" : "arm64"
        let bundled = config.root.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk-\(os)-\(arch)/claude").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return ClaudeLaunch.which("claude", path: config.environment["PATH"])
    }

    /// Starts a turn in the background (sendMessage() in server.mjs). Called on q.
    private func startRun(_ thread: ChatThread, text: String, files: [(name: String, size: Int, path: String)]) {
        guard let project = store.state.projects.first(where: { $0.id == thread.projectId }) else { return }
        let id = thread.id
        let prompt = files.isEmpty ? text
            : "\(text)\(text.isEmpty ? "" : "\n\n")Attached files (read them with the Read tool):\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
        let uploadDir = uploads.folderIfAny(id)
        let mode = modes.first { $0.id == thread.mode } ?? modes[0]
        let model = thread.model.isEmpty ? nil : thread.model

        let turn: ClaudeTurn
        var missingClaude = false
        if config.mock {
            turn = ClaudeTurn(backend: MockClaude(cwd: project.path, model: model, permissionMode: mode.sdk, resume: thread.sessionId), prompt: prompt)
        } else {
            let exe = claudeExecutable()
            missingClaude = exe == nil
            var launch = ClaudeLaunch(executable: exe ?? "claude", cwd: project.path)
            launch.model = model
            launch.permissionMode = mode.sdk
            launch.resume = thread.sessionId
            launch.environment = AgentEnvironment.build(guardPort: egress?.port, config.environment)
            if let d = uploadDir { launch.additionalDirectories = [d] }
            turn = ClaudeTurn(launch: launch, prompt: prompt)
        }
        let run = Run(turn)
        runs[id] = run

        turn.emit = { [weak self] ev in self?.turnEvent(id, ev) }
        turn.activity = { [weak self] a in self?.turnActivity(id, run, a) }
        turn.canUseTool = { [weak self] req, answer in
            guard let self else { return answer(.deny(message: "Run ended.", interrupt: false)) }
            ask(id, req, answer)
        }
        turn.onPermissionCancelled = { [weak self] requestId in self?.withdraw(requestId) }

        emit(id, files.isEmpty ? ["t": "user", "text": .string(text)]
             : ["t": "user", "text": .string(text), "files": .array(files.map { ["name": .string($0.name), "size": .number(Double($0.size))] })])
        if thread.title == "New thread" {
            let base = !text.isEmpty ? text : (files.first?.name ?? "New thread")
            let title = JS.prefix(CharnessServer.collapseSpace(base), 48)
            _ = try? store.updateState { s in
                var threads = s.threads
                if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].title = title; s.threads = threads }
            }
            broadcast(["type": "state"])
        }
        broadcast(["type": "busy", "threadId": .string(id), "busy": true])

        Thread.detachNewThread { [weak self] in
            if missingClaude {
                self?.q.sync { self?.emit(id, ["t": "error", "text": "Claude Code was not found. Run `npm install` in the Charness folder, or set HARNESS_CLAUDE_BIN to your claude binary."]) }
            } else {
                turn.run()
            }
            self?.finishRun(id)
        }
    }

    private func turnEvent(_ id: String, _ ev: JSONValue) { q.sync { emit(id, ev) } }

    private func turnActivity(_ id: String, _ run: Run, _ a: Activity) {
        q.sync {
            run.activity = a.json                // live feed only: kept with the run, never written to disk
            broadcast(["type": "activity", "threadId": .string(id), "activity": a.json])
        }
    }

    /// A permission prompt from Claude: shown to the user until they answer (or the run ends).
    private func ask(_ id: String, _ req: PermissionRequest, _ answer: @escaping (PermissionDecision) -> Void) {
        q.sync {
            var perm: JSONObject = ["id": .string(Store.newId()), "threadId": .string(id), "toolUseId": .string(req.toolUseId),
                                    "tool": .string(req.toolName), "input": clipInput(req.input)]
            if let t = req.title { perm["title"] = .string(t) }
            if let d = req.description { perm["description"] = .string(d) }
            perm["defaultToNo"] = .bool(JS.truthy(req.raw["default_to_no"]))
            let pid = perm["id"]!.stringValue!
            pending[pid] = Pending(perm: perm, input: req.input, requestId: req.requestId, answer: answer)
            pendingOrder.append(pid)
            broadcast(["type": "perm", "perm": .object(perm)])
        }
    }

    /// Claude withdrew a prompt.
    private func withdraw(_ requestId: String) {
        q.sync {
            if let pid = pendingOrder.first(where: { pending[$0]?.requestId == requestId }) {
                settle(pid, .deny(message: "Stopped by the user.", interrupt: true))
            }
        }
    }

    private func finishRun(_ id: String) {
        q.sync {
            for pid in pendingOrder where pending[pid]?.perm["threadId"]?.stringValue == id {
                settle(pid, .deny(message: "Run ended.", interrupt: false))
            }
            runs[id] = nil
            broadcast(["type": "busy", "threadId": .string(id), "busy": false])
            broadcast(["type": "state"])
            _ = try? store.updateState { _ in }
        }
    }

    /// text.replace(/\s+/g, ' ')
    static func collapseSpace(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inSpace = false
        for u in s.unicodeScalars {
            if Uploads.jsSpace(u) { if !inSpace { out.append(" ") }; inSpace = true } else { out.append(u); inSpace = false }
        }
        return String(out)
    }

    // MARK: git (read-only, hardened)

    private func git(_ cwd: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ClaudeLaunch.which("git", path: config.environment["PATH"]) ?? "/usr/bin/git")
        p.arguments = ["-c", "core.fsmonitor=false", "-c", "core.pager=cat"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var env = AgentEnvironment.base(config.environment)
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "") }
        var data = Data()
        var tooBig = false
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if data.count + chunk.count > 4 * 1024 * 1024 { tooBig = true; p.terminate() } else { data += chunk }
            }
            reader.signal()
        }
        let timedOut = reader.wait(timeout: .now() + 10) == .timedOut
        if timedOut { p.terminate(); _ = reader.wait(timeout: .now() + 2) }
        p.waitUntilExit()
        let ok = !timedOut && !tooBig && p.terminationReason == .exit && p.terminationStatus == 0
        return (ok, String(decoding: data, as: UTF8.self))
    }

    private func gitChanges(_ cwd: String) -> JSONValue {
        guard git(cwd, ["rev-parse", "--is-inside-work-tree"]).ok else { return ["isRepo": false] }
        let status = git(cwd, ["status", "--porcelain=v1", "-unormal"])
        var diff = git(cwd, ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "HEAD"])
        if !diff.ok { diff = git(cwd, ["diff", "--no-color", "--no-ext-diff", "--no-textconv"]) }
        let limit = 300 * 1024
        return ["isRepo": true, "status": .string(status.out), "diff": .string(JS.prefix(diff.out, limit)), "truncated": .bool(diff.out.utf16.count > limit)]
    }

    // MARK: routing

    private struct Fail: Error { let code: Int; let message: String }

    private func handle(_ req: HTTPRequest, _ res: HTTPResponse) {
        res.baseHeaders = CharnessServer.securityHeaders
        func fail(_ code: Int, _ msg: String) { res.json(code, ["error": .string(msg)]) }

        // 1) DNS-rebinding protection: only our own loopback names are accepted.
        let host = (req.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return fail(403, "bad host") }
        let path = req.path
        let method = req.method

        // 2) First visit with ?token=… → set a strict cookie and drop the token from the URL.
        if method == "GET" && path == "/", let t = req.query("token") {
            guard tokenOk(t) else { return fail(401, "bad token") }
            return res.send(302, [("Set-Cookie", "hk=\(token); HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000"), ("Location", "/")])
        }

        // 3) Everything else needs the cookie.
        guard tokenOk(cookie(req, "hk")) else {
            return res.send(401, [("Content-Type", "text/plain; charset=utf-8")],
                            Array("Not authorised. Open the full URL printed in the terminal (it contains ?token=…).\n".utf8))
        }

        // 4) State-changing requests must come from our own page.
        if method != "GET" && method != "HEAD" {
            guard req.headers["origin"] == "http://\(host)" else { return fail(403, "bad origin") }
            guard req.headers["x-harness"] == "1" else { return fail(403, "missing header") }
        }

        if method == "GET", let f = staticFiles[path] {
            return res.send(200, [("Content-Type", f.type), ("Cache-Control", "no-store")], f.body)
        }
        if method == "GET" && path == "/favicon.ico" { return res.send(204) }

        if method == "GET" && path == "/api/events" {
            guard res.startStream(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-store")]) else { return }
            res.write(": hello\n\n")
            q.sync { clients.append(res) }
            while Net.receive(res.fd) != nil {}   // until the browser goes away
            q.sync { clients.removeAll { $0 === res } }
            return
        }

        guard path.hasPrefix("/api/") else { return fail(404, "not found") }
        do {
            if let answer = try route(method, path, req, res) { return res.json(answer.0, answer.1) }
        } catch let f as Fail {
            return fail(f.code, f.message)
        } catch {
            return fail(400, "\(error)")
        }
        fail(404, "not found")
    }

    /// The request body as JSON (readBody() in server.mjs): {} when empty, at most 1 MB.
    private func body(_ req: HTTPRequest) throws -> JSONObject {
        if req.bodyTooLarge || req.body.count > 1024 * 1024 { throw Fail(code: 400, message: "body too large") }
        if req.body.isEmpty { return JSONObject() }
        guard let v = try? JSONValue.parse(req.body) else { throw Fail(code: 400, message: "bad json") }
        return v.objectValue ?? JSONObject()
    }

    private static func match(_ path: String, _ prefix: String) -> (id: String, sub: String?)? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let id = String(parts[0])
        guard Store.isValidId(id) else { return nil }
        if parts.count == 1 { return (id, nil) }
        let sub = String(parts[1])
        guard !sub.isEmpty, sub.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return nil }
        return (id, "/" + sub)
    }

    /// The API. Returns (status, JSON) to answer, or nil for "not found".
    private func route(_ method: String, _ path: String, _ req: HTTPRequest, _ res: HTTPResponse) throws -> (Int, JSONValue)? {
        // ---- state
        if method == "GET" && path == "/api/state" {
            return q.sync {
                let st = store.state
                return (200, [
                    "projects": .array(st.projects.map { .object($0.raw) }),
                    "threads": .array(st.threads.map(publicThread)),
                    "perms": .array(pendingOrder.compactMap { pending[$0].map { .object($0.perm) } }),
                    "models": .array(models),
                    "modes": .array(modes.map { ["id": .string($0.id), "label": .string($0.label)] }),
                    "mock": .bool(config.mock),
                    "guard": ["on": .bool(egress != nil), "allow": .array(allowList().map(JSONValue.string)), "log": .array(Array(netLog.suffix(200)))],
                ])
            }
        }

        // ---- projects
        if method == "POST" && path == "/api/projects" {
            let b = try body(req)
            let p = expandPath(JS.truthy(b["path"]) ? JS.string(b["path"]) : "")
            guard let real = CharnessServer.realPath(p), isDirectory(real) else { throw Fail(code: 400, message: "Not a folder: \(p)") }
            return try q.sync {
                if store.state.projects.contains(where: { $0.path == real }) { throw Fail(code: 409, message: "Already added") }
                let name = real.split(separator: "/").last.map(String.init) ?? ""   // path.basename(real) || real
                let project = Project(id: Store.newId(), name: name.isEmpty ? real : name, path: real)
                try store.updateState { $0.projects.append(project) }
                broadcast(["type": "state"])
                return (200, .object(project.raw))
            }
        }
        if let m = CharnessServer.match(path, "/api/projects/"), m.sub == nil {
            return try q.sync {
                guard let project = store.state.projects.first(where: { $0.id == m.id }) else { throw Fail(code: 404, message: "no such project") }
                guard method == "DELETE" else { return nil }
                let ids = store.state.threads.filter { $0.projectId == project.id }.map(\.id)
                if ids.contains(where: { runs[$0] != nil }) { throw Fail(code: 409, message: "A thread is still running") }
                for id in ids { try? store.deleteThreadFiles(id); uploads.removeAll(id) }
                try store.updateState { s in
                    s.threads = s.threads.filter { $0.projectId != project.id }
                    s.projects = s.projects.filter { $0.id != project.id }   // the folder on disk is untouched
                }
                broadcast(["type": "state"])
                return (200, ["ok": true])
            }
        }

        // ---- threads
        if method == "POST" && path == "/api/threads" {
            let b = try body(req)
            return try q.sync {
                guard case .string(let pid)? = b["projectId"], store.state.projects.contains(where: { $0.id == pid }) else {
                    throw Fail(code: 400, message: "unknown project")
                }
                let t = ChatThread(id: Store.newId(), projectId: pid, title: "New thread", model: "claude-sonnet-5-5", mode: "edits", now: nowMs())
                try store.updateState { $0.threads.append(t) }
                try store.updateThread(t.id) { _ in }
                broadcast(["type": "state"])
                return (200, publicThread(t))
            }
        }
        if let m = CharnessServer.match(path, "/api/threads/") {
            guard let thread = q.sync(execute: { store.state.threads.first { $0.id == m.id } }) else { throw Fail(code: 404, message: "no such thread") }
            let id = thread.id

            if m.sub == nil && method == "GET" {
                return try q.sync {
                    (200, ["thread": publicThread(thread), "messages": .array(try store.thread(id).messages),
                           "perms": .array(pendingFor(id)), "activity": runs[id]?.activity ?? .null])
                }
            }
            if m.sub == nil && method == "PATCH" {
                let b = try body(req)
                return try q.sync {
                    var t = thread
                    if case .string(let title)? = b["title"] {
                        let clean = JS.prefix(title.trimmingJSSpace(), 120)
                        if !clean.isEmpty { t.title = clean }
                    }
                    var failure: Fail?
                    if case .string(let model)? = b["model"] {
                        if models.contains(where: { $0.objectValue?["id"]?.stringValue == model }) { t.model = model }
                        else { failure = Fail(code: 400, message: "unknown model") }
                    }
                    if failure == nil, case .string(let mode)? = b["mode"] {
                        if modes.contains(where: { $0.id == mode }) { t.mode = mode } else { failure = Fail(code: 400, message: "unknown mode") }
                    }
                    try store.updateState { s in
                        var threads = s.threads
                        if let i = threads.firstIndex(where: { $0.id == id }) { threads[i] = t; s.threads = threads }
                    }
                    if let f = failure { throw f }
                    broadcast(["type": "state"])
                    return (200, publicThread(t))
                }
            }
            if m.sub == nil && method == "DELETE" {
                return try q.sync {
                    if runs[id] != nil { throw Fail(code: 409, message: "Thread is running — stop it first") }
                    try? store.deleteThreadFiles(id)
                    uploads.removeAll(id)
                    try store.updateState { $0.threads = $0.threads.filter { $0.id != id } }
                    broadcast(["type": "state"])
                    return (200, ["ok": true])
                }
            }
            if m.sub == "/files" && method == "POST" {
                // one attached file per request, as raw bytes; its name comes URL-encoded in X-File-Name
                if req.bodyTooLarge { throw Fail(code: 413, message: "File too large (limit \(Uploads.maxFileBytes / 1024 / 1024) MB)") }
                let raw = req.headers["x-file-name"] ?? "file"
                let saved = try uploads.save(id, name: raw.removingPercentEncoding ?? raw, bytes: req.body)
                return (200, ["name": .string(saved.name), "size": .number(Double(saved.size))])
            }
            if m.sub == "/send" && method == "POST" {
                let b = try body(req)
                let text = b["text"]?.stringValue?.trimmingJSSpace() ?? ""
                let names = b["files"]?.arrayValue ?? []
                if names.count > Uploads.maxFilesPerMessage { throw Fail(code: 400, message: "At most \(Uploads.maxFilesPerMessage) files per message") }
                let files = names.map { uploads.find(id, $0) }
                if files.contains(where: { $0 == nil }) { throw Fail(code: 400, message: "unknown attached file") }
                if (text.isEmpty && files.isEmpty) || text.utf16.count > 200_000 { throw Fail(code: 400, message: "empty or too long") }
                return try q.sync {
                    if runs[id] != nil { throw Fail(code: 409, message: "Already running") }
                    guard store.state.projects.contains(where: { $0.id == thread.projectId }) else { throw Fail(code: 400, message: "project missing") }
                    let current = store.state.threads.first { $0.id == id } ?? thread
                    startRun(current, text: text, files: files.compactMap { $0 })   // progress arrives over the live feed
                    return (202, ["ok": true])
                }
            }
            if m.sub == "/stop" && method == "POST" {
                let turn: ClaudeTurn? = q.sync {
                    guard let r = runs[id] else { return nil }
                    for pid in pendingOrder where pending[pid]?.perm["threadId"]?.stringValue == id {
                        settle(pid, .deny(message: "Stopped by the user.", interrupt: true))
                    }
                    return r.turn
                }
                turn?.stop()
                return (200, ["ok": true])
            }
            if m.sub == "/diff" && method == "GET" {
                guard let project = q.sync(execute: { store.state.projects.first { $0.id == thread.projectId } }) else {
                    throw Fail(code: 400, message: "project missing")
                }
                return (200, gitChanges(project.path))
            }
            return nil
        }

        // ---- permissions
        if method == "POST", let m = CharnessServer.match(path, "/api/permissions/"), m.sub == nil {
            let b = try body(req)
            return try q.sync {
                guard let p = pending[m.id] else { throw Fail(code: 404, message: "already answered") }
                if b["allow"] == true {
                    settle(m.id, .allow(updatedInput: p.input))
                } else {
                    if let tid = p.perm["threadId"]?.stringValue, store.state.threads.contains(where: { $0.id == tid }) {
                        let ev: JSONValue = ["t": "tool_denied", "id": p.perm["toolUseId"] ?? .null, "ts": .number(nowMs())]
                        _ = try? store.updateThread(tid) { $0.apply(ev) }
                        broadcast(["type": "thread", "threadId": .string(tid), "ev": ev])
                    }
                    settle(m.id, .deny(message: CharnessServer.denied, interrupt: false))
                }
                return (200, ["ok": true])
            }
        }

        // ---- network allow-list
        if method == "POST" && path == "/api/net/allow" {
            let b = try body(req)
            let h = (JS.truthy(b["host"]) ? JS.string(b["host"]) : "").trimmingJSSpace().lowercased()
            guard CharnessServer.isHostEntry(h) else { throw Fail(code: 400, message: "bad host") }
            return try q.sync {
                if !store.state.allowHosts.contains(h) { try store.updateState { $0.allowHosts.append(h) } }
                let list = JSONValue.array(allowList().map(JSONValue.string))
                broadcast(["type": "allow", "allow": list])
                return (200, ["allow": list])
            }
        }
        return nil
    }

    /// /^(\*\.)?[a-z0-9.-]+(:\d+)?$/
    static func isHostEntry(_ h: String) -> Bool {
        var s = Substring(h)
        if s.hasPrefix("*.") { s = s.dropFirst(2) }
        var name = s, port: Substring = ""
        if let colon = s.firstIndex(of: ":") { name = s[..<colon]; port = s[s.index(after: colon)...] }
        let okName = !name.isEmpty && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }
        let okPort = s.firstIndex(of: ":") == nil || (!port.isEmpty && port.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 })
        return okName && okPort
    }

    // Paths are handled as strings, as Node does: on macOS, URL would turn "ñ" into "n" + "~" (decomposed Unicode).

    private func expandPath(_ raw: String) -> String {
        var p = raw.trimmingJSSpace()
        let home = config.environment["HOME"] ?? NSHomeDirectory()
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + "/" + p.dropFirst(2) }
        return CharnessServer.resolve(p, cwd: FileManager.default.currentDirectoryPath)
    }

    /// path.resolve(cwd, p): absolute, without "." / ".." / repeated or trailing slashes.
    public static func resolve(_ p: String, cwd: String) -> String {
        var parts: [Substring] = []
        for part in ((p.hasPrefix("/") ? "" : cwd + "/") + p).split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// fs.realpathSync(): follows symlinks one component at a time and keeps every other name exactly as
    /// given (C realpath() returns names as the disk stores them, which on macOS can be decomposed Unicode).
    /// nil if something on the way doesn't exist.
    public static func realPath(_ p: String) -> String? {
        var pending = p.split(separator: "/").map(String.init)
        var done = ""   // resolved so far ("" = the root)
        var hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." || part.isEmpty { continue }
            if part == ".." { done = String(done[..<(done.lastIndex(of: "/") ?? done.startIndex)]); continue }
            let next = done + "/" + part
            var st = stat()
            guard lstat(next, &st) == 0 else { return nil }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                hops += 1
                if hops > 40 { return nil }   // a symlink loop
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(next, &buf, buf.count - 1)
                guard n >= 0 else { return nil }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if target.hasPrefix("/") { done = "" }
                pending = target.split(separator: "/").map(String.init) + pending
            } else {
                done = next
            }
        }
        return done.isEmpty ? "/" : done
    }

    private func isDirectory(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }
}
