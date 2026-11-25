// Runs the `claude` binary (Claude Code) and talks to it over its stream-json protocol, the way the official
// Agent SDK does, so Swift doesn't need the SDK or Node.
//
// The protocol (captured from Agent SDK 0.3.331 driving a recording stand-in; see mac/Fixtures/fake-claude.mjs):
//  * flags: --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio ...
//  * one JSON object per line in both directions
//  * host -> claude: {"type":"control_request","request":{"subtype":"initialize"}}, then the user message
//  * claude -> host: SDK messages (system, stream_event, assistant, user, result, tool_progress, ...) and
//    control requests; "can_use_tool" is the permission prompt, answered with a control_response
//  * when the result arrives the host closes stdin and claude exits; to stop early the host closes stdin,
//    then sends SIGTERM after 2 s and SIGKILL 5 s later (what the SDK does)

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How to start one `claude` run (the options the Agent SDK turned into flags for the retired lib/agent.mjs).
public struct ClaudeLaunch {
    /// Absolute path of the claude binary (or of `node`, with fake-claude.mjs in `executableArgs`, in tests).
    public var executable: String
    /// Put before the flags (the SDK's executableArgs).
    public var executableArgs: [String] = []
    public var cwd: String
    public var model: String?
    /// default | acceptEdits | plan | bypassPermissions
    public var permissionMode: String = "default"
    /// Session to continue, so context carries over between turns.
    public var resume: String?
    /// The child's whole environment. Nothing else is inherited: build it with AgentEnvironment.
    public var environment: [String: String] = [:]
    public var disallowedTools: [String] = ["AskUserQuestion"]
    public var settingSources: [String] = ["project"]
    /// Extra folders Claude may read, e.g. the thread's attached files (the SDK's additionalDirectories).
    public var additionalDirectories: [String] = []

    public init(executable: String, cwd: String) {
        self.executable = executable
        self.cwd = cwd
    }

    /// The flags, in the order the Agent SDK passes them for the options runTurn() uses.
    public var arguments: [String] {
        var a = executableArgs + ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
        if let m = model, !m.isEmpty { a.append("--model=\(m)") }
        a.append("--permission-prompt-tool=stdio")
        if let r = resume, !r.isEmpty { a.append("--resume=\(r)") }
        if !disallowedTools.isEmpty { a.append("--disallowedTools=\(disallowedTools.joined(separator: ","))") }
        a.append("--setting-sources=\(settingSources.joined(separator: ","))")
        a.append("--permission-mode=\(permissionMode)")
        if permissionMode == "bypassPermissions" { a.append("--allow-dangerously-skip-permissions") }
        a.append("--include-partial-messages")
        for dir in additionalDirectories { a.append("--add-dir=\(dir)") }
        return a
    }

    /// `environment` plus what the SDK adds for every run.
    public var childEnvironment: [String: String] {
        var env = environment
        // Tells Claude Code it is driven over stream-json by a program, not a terminal. The SDK uses "sdk-ts";
        // "sdk-cli" is the same kind of entry point for programs that speak the protocol themselves.
        if env["CLAUDE_CODE_ENTRYPOINT"] == nil { env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli" }
        if env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == nil { env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1" }
        if env["BUN_ENABLE_CRASH_REPORTING"] == nil && env["BUN_CRASH_REPORT_URL"] == nil { env["BUN_ENABLE_CRASH_REPORTING"] = "0" }
        env["NODE_OPTIONS"] = nil
        env["DEBUG"] = nil
        return env
    }

    /// Finds a program on a PATH-style list, like the shell does. nil if not found.
    public static func which(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (path ?? "").split(separator: ":") where !dir.isEmpty {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

/// A tool permission prompt from Claude Code (control request "can_use_tool").
public struct PermissionRequest {
    public let requestId: String
    public let toolName: String
    public let input: JSONValue
    public let toolUseId: String
    public let title: String?
    public let description: String?
    /// Everything Claude Code sent, for fields this code doesn't use yet (suggestions, blocked path, ...).
    public let raw: JSONObject
}

public enum PermissionDecision {
    case allow(updatedInput: JSONValue)
    case deny(message: String, interrupt: Bool)
}

/// How the process ended.
public struct ClaudeExit {
    public enum Reason { case exited, signal, notStarted }
    public let reason: Reason
    /// Exit code, or signal number.
    public let code: Int32
    /// The last ~1500 characters of stderr.
    public let stderrTail: String

    public var isClean: Bool { reason == .exited && code == 0 }
}

/// Where a turn's messages come from: the real `claude` process, or the built-in mock (MockClaude).
/// Callbacks are called one at a time, in order.
public protocol ClaudeBackend: AnyObject {
    var onMessage: (JSONObject) -> Void { get set }
    var onPermission: (PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void { get set }
    var onPermissionCancelled: (String) -> Void { get set }
    var onProtocolError: (String) -> Void { get set }
    /// Shown in "Could not start Claude Code (…)".
    var label: String { get }
    /// Whether nothing more is reported after stop() (true for the real Claude Code, like the SDK).
    var stopsReportingOnStop: Bool { get }
    func start(prompt: String) throws
    func closeInput()
    func stop()
    func waitUntilExit() -> ClaudeExit
}

/// One `claude` process. Callbacks run on an internal serial queue, one at a time, in the order the lines arrive.
public final class ClaudeProcess: ClaudeBackend, @unchecked Sendable {
    public let launch: ClaudeLaunch

    /// Every SDK message (system, stream_event, assistant, user, result, tool_progress, ...).
    public var onMessage: (JSONObject) -> Void = { _ in }
    /// A permission prompt. Call `answer` exactly once (later calls are ignored).
    public var onPermission: (PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void = { _, answer in
        answer(.deny(message: "No one is there to approve this.", interrupt: false))
    }
    /// Claude Code withdrew a prompt (control_cancel_request); the UI should remove it.
    public var onPermissionCancelled: (String) -> Void = { _ in }
    /// Something about the protocol went wrong (e.g. initialize was refused). The run is being stopped.
    public var onProtocolError: (String) -> Void = { _ in }

    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let queue = DispatchQueue(label: "charness.claude")
    private let writeLock = NSLock()
    private var stdinClosed = false
    private let readers = DispatchGroup()
    private var lineBuffer: [UInt8] = []
    private var stderrTail = ""
    private let stderrLock = NSLock()
    private var answered = Set<String>()
    private var initializeId: String?
    private var prompt = ""
    private var started = false

    public init(launch: ClaudeLaunch) { self.launch = launch }

    public var label: String { launch.executable }
    public var stopsReportingOnStop: Bool { true }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Starts claude and sends `prompt` once claude has accepted `initialize`.
    public func start(prompt: String) throws {
        signal(SIGPIPE, SIG_IGN)   // a write to a claude that already exited must be an error, not kill us
        self.prompt = prompt
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.childEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd, isDirectory: true)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        started = true

        let out = stdoutPipe.fileHandleForReading.fileDescriptor
        let err = stderrPipe.fileHandleForReading.fileDescriptor
        readers.enter()
        DispatchQueue.global().async { [self] in
            ClaudeProcess.readAll(out) { chunk in self.queue.async { self.feed(chunk) } }
            self.queue.async { self.readers.leave() }   // after every chunk already queued
        }
        readers.enter()
        DispatchQueue.global().async { [self] in
            ClaudeProcess.readAll(err) { chunk in
                self.stderrLock.lock()
                self.stderrTail = String((self.stderrTail + String(decoding: chunk, as: UTF8.self)).suffix(1500))
                self.stderrLock.unlock()
            }
            self.readers.leave()
        }

        let id = ClaudeProcess.requestId()
        queue.sync { initializeId = id }
        send(["request_id": .string(id), "type": "control_request", "request": ["subtype": "initialize"]])
    }

    /// Closes claude's stdin: after the result this makes claude exit (the SDK does the same).
    public func closeInput() {
        writeLock.lock(); defer { writeLock.unlock() }
        if stdinClosed { return }
        stdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Stops the run the way the SDK does: close stdin, SIGTERM after 2 s, SIGKILL 5 s after that.
    public func stop() {
        closeInput()
        guard started else { return }
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard p.isRunning else { return }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Blocks until claude has exited and every line it wrote has been handled.
    public func waitUntilExit() -> ClaudeExit {
        guard started else { return ClaudeExit(reason: .notStarted, code: -1, stderrTail: "") }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 2)   // a grandchild holding the pipe open must not hang us
        queue.sync {}
        stderrLock.lock(); let tail = stderrTail; stderrLock.unlock()
        let reason: ClaudeExit.Reason = process.terminationReason == .uncaughtSignal ? .signal : .exited
        return ClaudeExit(reason: reason, code: process.terminationStatus, stderrTail: tail)
    }

    // MARK: reading (on `queue`)

    private static func readAll(_ fd: Int32, _ chunk: ([UInt8]) -> Void) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { chunk(Array(buf[0..<n])) }
            else if n < 0 && errno == EINTR { continue }
            else { return }
        }
    }

    private func feed(_ chunk: [UInt8]) {
        lineBuffer.append(contentsOf: chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = Array(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            guard case .object(let msg)? = try? JSONValue.parse(line) else { continue }   // like the SDK: skip non-JSON lines
            handle(msg)
        }
    }

    private func handle(_ msg: JSONObject) {
        switch msg["type"]?.stringValue {
        case "control_response":
            let response = msg["response"]?.objectValue
            if let id = response?["request_id"]?.stringValue, id == initializeId {
                initializeId = nil
                if response?["subtype"]?.stringValue == "success" {
                    send(["type": "user", "session_id": "", "message": ["role": "user", "content": [["type": "text", "text": .string(prompt)]]], "parent_tool_use_id": nil])
                } else {
                    onProtocolError("Claude Code refused to start: \(response?["error"]?.stringValue ?? "initialize failed")")
                    stop()
                }
            }
        case "control_request":
            if let id = msg["request_id"]?.stringValue, let request = msg["request"]?.objectValue { controlRequest(id, request) }
        case "control_cancel_request":
            if let id = msg["request_id"]?.stringValue { onPermissionCancelled(id) }
        case "keep_alive", "transcript_mirror":
            break
        default:
            onMessage(msg)
        }
    }

    private func controlRequest(_ id: String, _ request: JSONObject) {
        switch request["subtype"]?.stringValue {
        case "can_use_tool":
            let toolUseId = request["tool_use_id"]?.stringValue ?? ""
            let req = PermissionRequest(
                requestId: id, toolName: request["tool_name"]?.stringValue ?? "", input: request["input"] ?? .object(JSONObject()),
                toolUseId: toolUseId, title: request["title"]?.stringValue, description: request["description"]?.stringValue, raw: request)
            onPermission(req) { [self] decision in
                let first: Bool = { answerLock.lock(); defer { answerLock.unlock() }; return answered.insert(id).inserted }()
                guard first else { return }
                var body: JSONObject
                switch decision {
                case .allow(let input):
                    body = ["behavior": "allow", "updatedInput": input]
                case .deny(let message, let interrupt):
                    body = ["behavior": "deny", "message": .string(message)]
                    if interrupt { body["interrupt"] = true }
                }
                body["toolUseID"] = .string(toolUseId)
                send(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": .object(body)]])
            }
        case "remote_tool_call", "remote_plumbing_call", "remote_tools_probe", "remote_tools_reannounce", "request_user_dialog":
            break   // not for this kind of host; the SDK leaves these unanswered too
        case "elicitation":
            send(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": ["action": "decline"]]])
        default:
            let what = request["subtype"]?.stringValue ?? "?"
            send(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string("Charness does not support \(what)")]])
        }
    }
    private let answerLock = NSLock()

    // MARK: writing (any thread)

    private func send(_ value: JSONValue) {
        let bytes = Array((value.jsonString() + "\n").utf8)
        writeLock.lock(); defer { writeLock.unlock() }
        if stdinClosed { return }
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        var offset = 0
        bytes.withUnsafeBytes { buf in
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return }   // claude has gone; its exit is reported separately
                offset += n
            }
        }
    }

    private static func requestId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<13).map { _ in chars.randomElement()! })
    }
}
