// One user turn (ported from runTurn() in lib/agent.mjs, the retired Node version) with Claude Code. Turns the stream of SDK messages
// into the same UI events (the shapes Reducer folds into a thread) and the same live activity feed,
// and routes permission prompts to the host. mac/Fixtures/turns/*.json hold what the Node version reports for
// the same runs (recorded before it was retired); `swift run core-checks` requires exactly the same.

import Foundation

// MARK: - environment (lib/agent.mjs: PASS, FORCED, baseEnv, buildEnv)

/// The child process gets only an allow-listed environment (no AWS_*, GITHUB_TOKEN, SSH_AUTH_SOCK...).
public enum AgentEnvironment {
    static let pass: Set<String> = [
        // basics
        "PATH", "HOME", "USER", "USERNAME", "LOGNAME", "SHELL", "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE",
        "LC_MESSAGES", "TERM", "TMPDIR", "TMP", "TEMP", "TZ",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
        // windows
        "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
        "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA", "HOMEDRIVE", "HOMEPATH", "SYSTEMDRIVE",
        // how Claude authenticates
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CONFIG_DIR",
        // custom CA bundles
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    ]

    static let forced: [String: String] = [
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
        "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_BUG_COMMAND": "1",
        "DO_NOT_TRACK": "1",
    ]

    /// Allow-listed slice of `environment` (+ anything named in HARNESS_PASS_ENV). Like baseEnv().
    public static func base(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let extra = (environment["HARNESS_PASS_ENV"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        var out: [String: String] = [:]
        for (k, v) in environment where pass.contains(k.uppercased()) || extra.contains(k.uppercased()) { out[k] = v }
        return out
    }

    /// base() + telemetry/updates off + the egress guard as proxy. Like buildEnv().
    public static func build(guardPort: Int? = nil, _ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base(environment).merging(forced) { _, forced in forced }
        if let port = guardPort, port != 0 {
            let url = "http://127.0.0.1:\(port)"
            for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { env[k] = url }
            // NO_PROXY from the user's shell is intentionally NOT passed through: it could bypass the guard.
        }
        return env
    }
}

// MARK: - small JavaScript-compatible helpers

enum JS {
    /// JavaScript's String(x) for a JSON value; null/missing become "" (the `?? ''` in the Node code).
    static func string(_ v: JSONValue?) -> String {
        switch v {
        case .none, .some(.null): return ""
        case .some(.string(let s)): return s
        case .some(.number(let d)): return JSONValue.jsNumber(d)
        case .some(.bool(let b)): return b ? "true" : "false"
        case .some(.array(let a)): return a.map { $0 == .null ? "" : string($0) }.joined(separator: ",")
        case .some(.object): return "[object Object]"
        }
    }

    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.number(let d)): return d != 0 && !d.isNaN
        case .some(.string(let s)): return !s.isEmpty
        default: return true
        }
    }

    /// s.slice(0, n): the first n UTF-16 code units (a split surrogate pair is dropped, not kept half).
    static func prefix(_ s: String, _ n: Int) -> String {
        let u = s.utf16
        guard u.count > n else { return s }
        var cut = u.index(u.startIndex, offsetBy: n)
        if let str = String(u[..<cut]) { return str }
        cut = u.index(before: cut)
        return String(u[..<cut]) ?? ""
    }

    static func utf16Count(_ s: String) -> Int { s.utf16.count }
}

/// One-line summary of a tool call. Port of toolSummary() in the retired web UI's reduce.js.
public func toolSummary(_ name: String, _ input: JSONValue?) -> String {
    let i = input?.objectValue ?? JSONObject()
    func line(_ s: String) -> String { JS.prefix(String(s.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""), 140) }
    func first(_ v: JSONValue?) -> String { line(JS.string(v)) }
    switch name {
    case "Bash": return first(i["command"])
    case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
        return first(JS.truthy(i["file_path"]) ? i["file_path"] : i["notebook_path"])
    case "Grep":
        return line(JS.string(i["pattern"]) + (JS.truthy(i["path"]) ? "  in \(JS.string(i["path"]))" : ""))
    case "Glob": return first(i["pattern"])
    case "WebFetch": return first(i["url"])
    case "WebSearch": return first(i["query"])
    case "Task", "Agent": return first(i["description"])
    case "TodoWrite": return "\(i["todos"]?.arrayValue?.count ?? 0) items"
    default: return first(i.entries.first(where: { $0.value.stringValue != nil })?.value)
    }
}

/// Strings longer than 20000 characters are cut, as clipInput() does, so huge inputs don't flood the UI.
func clipInput(_ input: JSONValue?) -> JSONValue {
    var out = JSONObject()
    for (k, v) in input?.objectValue?.entries ?? [] {
        if case .string(let s) = v, JS.utf16Count(s) > 20000 { out[k] = .string(JS.prefix(s, 20000) + "\n…[truncated]") }
        else { out[k] = v }
    }
    return .object(out)
}

/// A tool result's content as text (stringify() in lib/agent.mjs).
func resultText(_ c: JSONValue?) -> String {
    switch c {
    case .some(.string(let s)): return s
    case .some(.array(let items)):
        return items.map { x -> String in
            let o = x.objectValue
            if o?["type"]?.stringValue == "text" { return JS.string(o?["text"]) }
            let t = JS.string(o?["type"])
            return "[\(t.isEmpty ? "data" : t)]"
        }.joined(separator: "\n")
    case .none: return ""
    case .some(let v): return v.jsonString(pretty: true)
    }
}

// MARK: - live activity (activityTracker() in lib/agent.mjs)

public struct ActivityStep: Equatable {
    public let id: String
    public let text: String
    public let sub: Bool
    public let status: String   // running | ok | error

    public var json: JSONValue { ["id": .string(id), "text": .string(text), "sub": .bool(sub), "status": .string(status)] }
}

public struct Activity: Equatable {
    /// What Claude is doing right now; nil when the turn is over.
    public let now: String?
    /// When `now` started, in ms since 1970.
    public let since: Double
    /// The latest tool calls of this turn, sub-agents' included.
    public let steps: [ActivityStep]

    public var json: JSONValue {
        ["now": now.map(JSONValue.string) ?? .null, "since": .number(since), "steps": .array(steps.map(\.json))]
    }
}

final class ActivityTracker {
    static let maxSteps = 8
    private final class Step { let id: String; let text: String; let sub: Bool; var status = "running"
        init(id: String, text: String, sub: Bool) { self.id = id; self.text = text; self.sub = sub } }
    private var steps: [Step] = []
    private var byId: [String: Step] = [:]
    private var current: String?
    private var since = (Date().timeIntervalSince1970 * 1000).rounded(.down)
    private let report: (Activity) -> Void

    init(_ report: @escaping (Activity) -> Void) { self.report = report }

    private func send() {
        report(Activity(now: current, since: since, steps: steps.suffix(ActivityTracker.maxSteps).map {
            ActivityStep(id: $0.id, text: $0.text, sub: $0.sub, status: $0.status)
        }))
    }
    private func label(_ s: Step) -> String { s.sub ? "↳ \(s.text)" : s.text }

    func now(_ text: String?) {
        if text == current { return }
        current = text
        since = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        send()
    }
    func tool(_ id: String, _ name: String, _ input: JSONValue?, sub: Bool) {
        if id.isEmpty || byId[id] != nil { return }
        let summary = toolSummary(name, input)
        let s = Step(id: id, text: summary.isEmpty ? name : "\(name): \(summary)", sub: sub)
        steps.append(s); byId[id] = s
        if steps.count > 200 { byId[steps.removeFirst().id] = nil }
        current = label(s)
        since = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        send()
    }
    func running(_ id: String) { if let s = byId[id] { now(label(s)) } }
    func result(_ id: String, isError: Bool) {
        if let s = byId[id], s.status == "running" { s.status = isError ? "error" : "ok"; send() }
    }
    func end() { current = nil; send() }
}

// MARK: - one turn

/// One user turn, like runTurn(). Create, set the callbacks, then call run() off the main thread;
/// stop() may be called from any thread.
public final class ClaudeTurn: @unchecked Sendable {
    /// UI events, the same shapes runTurn() emits: session, delta, tool_use, tool_result, error, end.
    public var emit: (JSONValue) -> Void = { _ in }
    /// The live activity feed.
    public var activity: (Activity) -> Void = { _ in }
    /// Permission prompts; answer exactly once.
    public var canUseTool: (PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void = { _, answer in
        answer(.deny(message: "No one is there to approve this.", interrupt: false))
    }
    public var onPermissionCancelled: (String) -> Void = { _ in }

    private let process: ClaudeBackend
    private let prompt: String
    private let stopLock = NSLock()
    private var stopped = false
    private let dropAfterStop: Bool
    // only touched on the process's queue (message callbacks) or after it has drained
    private var streamed = Set<String>()
    private var shown = ""
    private var gotResult = false
    private var protocolError: String?
    private lazy var act = ActivityTracker { [unowned self] in self.activity($0) }

    /// A turn with the real Claude Code.
    public convenience init(launch: ClaudeLaunch, prompt: String) {
        self.init(backend: ClaudeProcess(launch: launch), prompt: prompt)
    }

    /// A turn with any backend, e.g. MockClaude.
    public init(backend: ClaudeBackend, prompt: String) {
        process = backend
        self.prompt = prompt
        dropAfterStop = backend.stopsReportingOnStop
    }

    private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

    /// Like pressing Stop: the turn ends with "Stopped." and nothing after that is reported.
    public func stop() {
        stopLock.lock(); stopped = true; stopLock.unlock()
        process.stop()
    }

    /// Runs the turn to the end. Blocks.
    public func run() {
        // after Stop the Agent SDK reports nothing more from claude; the Node mock does finish its current step
        process.onMessage = { [unowned self] msg in if !(self.dropAfterStop && self.isStopped) { self.handle(msg) } }
        process.onProtocolError = { [unowned self] text in self.protocolError = text }
        process.onPermissionCancelled = { [unowned self] id in self.onPermissionCancelled(id) }
        process.onPermission = { [unowned self] req, answer in
            if self.isStopped { return answer(.deny(message: "Stopped by the user.", interrupt: true)) }
            self.act.now("Waiting for your approval: \(req.toolName)")
            self.canUseTool(req) { decision in
                if case .allow = decision { self.act.running(req.toolUseId) } else { self.act.now("Thinking…") }
                answer(decision)
            }
        }

        act.now("Starting Claude Code…")
        do {
            try process.start(prompt: prompt)
        } catch {
            emitError("Could not start Claude Code (\(process.label)): \(error.localizedDescription)")
            return
        }
        let exit = process.waitUntilExit()

        if isStopped {
            emitError("Stopped.")
        } else if let p = protocolError {
            emitError(p)
        } else if !gotResult && !exit.isClean {
            // the SDK would throw "Claude Code process exited with code N"; runTurn adds the stderr tail once
            var what = exit.reason == .signal
                ? "Claude Code process terminated by signal \(ClaudeTurn.signalName(exit.code))"
                : "Claude Code process exited with code \(exit.code)"
            let tail = exit.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { what += "\n\n\(tail)" }
            emitError(what)
        }
    }

    private func emitError(_ text: String) { emit(["t": "error", "text": .string(text)]) }

    private func say(_ text: String) {
        shown += text
        emit(["t": "delta", "text": .string(text)])
    }

    private func handle(_ msg: JSONObject) {
        let parent = JS.truthy(msg["parent_tool_use_id"])
        switch msg["type"]?.stringValue {
        case "system":
            let subtype = msg["subtype"]?.stringValue
            if subtype == "init" {
                var ev: JSONObject = ["t": "session"]
                if let s = msg["session_id"], s != .null { ev["sessionId"] = s }
                if let m = msg["model"], m != .null { ev["model"] = m }
                emit(.object(ev))
                act.now("Thinking…")
            }
            if subtype == "status" && msg["status"]?.stringValue == "compacting" { act.now("Compacting the conversation…") }
            if subtype == "api_retry" {
                let status = JS.truthy(msg["error_status"]) ? " \(JS.string(msg["error_status"]))" : ""
                act.now("Claude API error\(status), retrying (\(JS.string(msg["attempt"]))/\(JS.string(msg["max_retries"])))…")
            }

        case "tool_progress":
            act.running(JS.string(msg["tool_use_id"]))

        case "stream_event":
            if parent { break }   // ignore sub-agent chatter
            let e = msg["event"]?.objectValue
            if e?["type"]?.stringValue == "content_block_start" {
                let block = e?["content_block"]?.objectValue
                switch block?["type"]?.stringValue {
                case "thinking", "redacted_thinking": act.now("Thinking…")
                case "text": act.now("Writing…")
                case "tool_use": act.now("Preparing \(JS.string(block?["name"]))…")
                default: break
                }
            }
            if e?["type"]?.stringValue == "message_start", let id = e?["message"]?.objectValue?["id"]?.stringValue, !id.isEmpty {
                streamed.insert(id)
            }
            if e?["type"]?.stringValue == "content_block_delta",
               let d = e?["delta"]?.objectValue, d["type"]?.stringValue == "text_delta" {
                say(JS.string(d["text"]))
            }

        case "assistant":
            let message = msg["message"]?.objectValue
            let content = message?["content"]?.arrayValue ?? []
            if parent {   // a sub-agent's step: shown live only, not saved
                for b in content.compactMap(\.objectValue) where b["type"]?.stringValue == "tool_use" {
                    act.tool(JS.string(b["id"]), JS.string(b["name"]), b["input"], sub: true)
                }
                break
            }
            let id = message?["id"]?.stringValue
            for b in content.compactMap(\.objectValue) {
                if b["type"]?.stringValue == "text", JS.truthy(b["text"]), !(id.map(streamed.contains) ?? false) {
                    say(JS.string(b["text"]))
                }
                if b["type"]?.stringValue == "tool_use" {
                    emit(["t": "tool_use", "id": b["id"] ?? .null, "name": b["name"] ?? .null, "input": clipInput(b["input"])])
                    act.tool(JS.string(b["id"]), JS.string(b["name"]), b["input"], sub: false)
                }
            }

        case "user":
            let content = msg["message"]?.objectValue?["content"]?.arrayValue ?? []
            let results = content.compactMap(\.objectValue).filter { $0["type"]?.stringValue == "tool_result" }
            for b in results { act.result(JS.string(b["tool_use_id"]), isError: JS.truthy(b["is_error"])) }
            if parent { break }
            for b in results {
                emit(["t": "tool_result", "id": b["tool_use_id"] ?? .null,
                      "output": .string(JS.prefix(resultText(b["content"]), 8000)), "isError": .bool(JS.truthy(b["is_error"]))])
                act.now("Thinking…")
            }

        case "result":
            gotResult = true
            let subtype = JS.string(msg["subtype"])
            if JS.truthy(msg["is_error"]) || subtype != "success" {
                let errors = msg["errors"]?.arrayValue?.map { JS.string($0) } ?? []
                let why = JS.truthy(msg["is_error"]) && JS.truthy(msg["result"])
                    ? JS.string(msg["result"])
                    : "Run ended: \(subtype)\(errors.isEmpty ? "" : " — \(errors.joined(separator: "; "))")"
                if !shown.contains(why) { emitError(why) }
                let lower = why.lowercased()
                if ["invalid api key", "not logged in", "please run /login", "authentication"].contains(where: { lower.contains($0) }) {
                    emitError("Authentication failed. Start the harness from a terminal that has ANTHROPIC_API_KEY set, or log in first with `claude auth login` (Claude Code CLI).")
                }
            }
            var end: JSONObject = ["t": "end"]
            if let v = msg["total_cost_usd"] { end["cost"] = v }
            if let v = msg["num_turns"] { end["turns"] = v }
            if let v = msg["duration_ms"] { end["ms"] = v }
            emit(.object(end))
            act.end()
            process.closeInput()   // the SDK closes stdin after the result; claude then exits

        default:
            break
        }
    }

    static func signalName(_ n: Int32) -> String {
        switch n {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        case 15: return "SIGTERM"
        default: return "signal \(n)"
        }
    }
}
