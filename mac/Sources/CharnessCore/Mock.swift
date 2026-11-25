// Swift port of mockQuery() in lib/agent.mjs (`npm run mock`): a pretend Claude Code that sends the same
// messages as the real one, with no process, no network and no API key. It lets you try the UI and test the
// permission flow safely. `swift run core-checks` requires it to produce exactly what the Node mock produces
// (mac/Fixtures/turns/mock-*.json), apart from its random ids.

import Foundation

public final class MockClaude: ClaudeBackend, @unchecked Sendable {
    public var onMessage: (JSONObject) -> Void = { _ in }
    public var onPermission: (PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void = { _, answer in
        answer(.deny(message: "No one is there to approve this.", interrupt: false))
    }
    public var onPermissionCancelled: (String) -> Void = { _ in }
    public var onProtocolError: (String) -> Void = { _ in }
    public var label: String { "mock" }
    /// Like the Node mock: after Stop it still reports the step it was on, then gives up at its next word.
    public var stopsReportingOnStop: Bool { false }

    private let cwd: String
    private let model: String?
    private let permissionMode: String
    private let resume: String?
    private let queue = DispatchQueue(label: "charness.mock")   // callbacks run here, one at a time
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var aborted = false
    private var pendingAnswer: ((PermissionDecision) -> Void)?
    private var started = false

    /// The same options the Node mock reads: cwd, model, permission mode, session to resume.
    public init(cwd: String, model: String?, permissionMode: String, resume: String?) {
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.resume = resume
    }

    public func start(prompt: String) throws {
        started = true
        DispatchQueue.global().async { [self] in
            script(prompt)
            finished.signal()
        }
    }

    public func closeInput() {}

    /// Like aborting the Node mock: a prompt that is still waiting is answered "Stopped by the user."
    /// (what the server does), and the mock gives up at its next word of text.
    public func stop() {
        lock.lock()
        aborted = true
        let answer = pendingAnswer
        pendingAnswer = nil
        lock.unlock()
        answer?(.deny(message: "Stopped by the user.", interrupt: true))
    }

    public func waitUntilExit() -> ClaudeExit {
        if started { finished.wait() }
        return ClaudeExit(reason: .exited, code: 0, stderrTail: "")
    }

    // MARK: the script (mirrors mockQuery line by line)

    private var isAborted: Bool { lock.lock(); defer { lock.unlock() }; return aborted }
    private func sleep(_ ms: Double) { Thread.sleep(forTimeInterval: ms / 1000) }
    private func yield(_ msg: JSONObject) { queue.sync { onMessage(msg) } }
    private static func randomId() -> String {
        // like Math.random().toString(36).slice(2)
        String((0..<11).map { _ in Array("0123456789abcdefghijklmnopqrstuvwxyz").randomElement()! })
    }

    private struct Aborted: Error {}

    /// The words of `text` as /\S+\s*/g matches them (leading whitespace is dropped, as in JS).
    public static func words(_ text: String) -> [String] {
        func space(_ u: Unicode.Scalar) -> Bool {   // JavaScript's \s
            switch u.value {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var inSpace = false
        for u in text.unicodeScalars {
            if space(u) {
                if current.isEmpty { continue }   // whitespace before the first word is not part of any match
                inSpace = true
                current.append(u)
            } else {
                if inSpace { out.append(String(current)); current = String.UnicodeScalarView(); inSpace = false }
                current.append(u)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    private func say(_ text: String) throws {
        for w in MockClaude.words(text) {
            if isAborted { throw Aborted() }
            sleep(12)
            yield(["type": "stream_event", "parent_tool_use_id": nil, "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": .string(w)]]])
        }
    }

    private func block(_ kind: String) -> JSONObject {
        ["type": "stream_event", "parent_tool_use_id": nil, "event": ["type": "content_block_start", "content_block": ["type": .string(kind)]]]
    }

    private func askPermission(_ name: String, _ input: JSONValue, _ toolId: String) -> PermissionDecision {
        let gate = DispatchSemaphore(value: 0)
        var decision = PermissionDecision.deny(message: "Stopped by the user.", interrupt: true)
        var answered = false
        let answer: (PermissionDecision) -> Void = { [self] d in   // the first answer wins (the user's, or Stop's)
            lock.lock()
            if answered { lock.unlock(); return }
            answered = true
            decision = d
            pendingAnswer = nil
            lock.unlock()
            gate.signal()
        }
        lock.lock()
        if aborted { lock.unlock(); return decision }
        pendingAnswer = answer
        lock.unlock()
        let req = PermissionRequest(requestId: MockClaude.randomId(), toolName: name, input: input, toolUseId: toolId,
                                    title: "Claude wants to use \(name)", description: nil,
                                    raw: ["subtype": "can_use_tool", "tool_name": .string(name), "input": input, "tool_use_id": .string(toolId)])
        queue.sync { onPermission(req, answer) }
        gate.wait()
        return decision
    }

    private func script(_ prompt: String) {
        do { try run(prompt) } catch { /* stopped: the turn reports "Stopped." */ }
    }

    private func run(_ prompt: String) throws {
        let sid = resume ?? "mock-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
        yield(["type": "system", "subtype": "init", "session_id": .string(sid), "model": .string(model.flatMap { $0.isEmpty ? nil : $0 } ?? "mock-model")])

        let msgId = "msg_\(MockClaude.randomId())"
        yield(["type": "stream_event", "parent_tool_use_id": nil, "event": ["type": "message_start", "message": ["id": .string(msgId)]]])
        yield(block("thinking"))
        sleep(250)
        yield(block("text"))

        let lower = prompt.lowercased()
        let wantsEdit = ["edit", "write", "change"].contains { lower.contains($0) }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let intro = wantsEdit
            ? "Mock mode (\(permissionMode)). I'll make a small edit in `\(folder)`.\n\n"
            : "Mock mode (\(permissionMode)) — no real model is called here.\n\nYou said: **\(JS.prefix(prompt, 80))**\n\nHere's some formatting to check the renderer:\n\n- a list item with `inline code`\n- another with a [link](https://example.com)\n\n| Tool | Needs approval |\n|------|----------------|\n| Read | no |\n| Bash | yes |\n\n```js\nconsole.log(\"hello from a code block\");\n```\n\nNow I'll run a command.\n\n"
        try say(intro)

        let toolId = "toolu_\(MockClaude.randomId())"
        let input: JSONValue = wantsEdit
            ? ["file_path": .string("\(cwd)/hello.txt"), "old_string": "hello world", "new_string": "hello, harness"]
            : ["command": "ls -la", "description": "List files"]
        let name = wantsEdit ? "Edit" : "Bash"
        yield(["type": "assistant", "parent_tool_use_id": nil, "message": ["id": .string(msgId), "content": [["type": "tool_use", "id": .string(toolId), "name": .string(name), "input": input]]]])

        let decision = permissionMode == "plan"
            ? PermissionDecision.deny(message: "plan mode: no execution", interrupt: false)
            : askPermission(name, input, toolId)
        var ok = false
        var denial = ""
        switch decision {
        case .allow: ok = true
        case .deny(let message, _): denial = message
        }
        if ok && name == "Bash" {   // a command that takes a moment, so the activity timer shows
            for sec in 1...2 {
                sleep(400)
                yield(["type": "tool_progress", "tool_use_id": .string(toolId), "tool_name": .string(name), "parent_tool_use_id": nil, "elapsed_time_seconds": .number(Double(sec))])
            }
        }
        yield(["type": "user", "parent_tool_use_id": nil, "message": ["content": [[
            "type": "tool_result", "tool_use_id": .string(toolId), "is_error": .bool(!ok),
            "content": .string(ok ? "total 8\ndrwxr-xr-x  2 you you 4096 .\n-rw-r--r--  1 you you   12 hello.txt" : denial),
        ]]]])

        if ok && !wantsEdit {   // a sub-agent whose steps appear in the live activity feed
            let taskId = "toolu_\(MockClaude.randomId())"
            yield(["type": "assistant", "parent_tool_use_id": nil, "message": ["id": .string(msgId), "content": [[
                "type": "tool_use", "id": .string(taskId), "name": "Task",
                "input": ["description": "Look around the project", "prompt": "List and read the files.", "subagent_type": "Explore"],
            ]]]])
            let steps: [(String, JSONValue, String)] = [("Glob", ["pattern": "**/*"], "hello.txt"),
                                                        ("Read", ["file_path": .string("\(cwd)/hello.txt")], "hello world")]
            for (tool, inp, out) in steps {
                let subId = "toolu_\(MockClaude.randomId())"
                sleep(200)
                yield(["type": "assistant", "parent_tool_use_id": .string(taskId), "message": ["id": .string("msg_sub_\(subId)"), "content": [["type": "tool_use", "id": .string(subId), "name": .string(tool), "input": inp]]]])
                sleep(200)
                yield(["type": "user", "parent_tool_use_id": .string(taskId), "message": ["content": [["type": "tool_result", "tool_use_id": .string(subId), "content": .string(out)]]]])
            }
            yield(["type": "user", "parent_tool_use_id": nil, "message": ["content": [["type": "tool_result", "tool_use_id": .string(taskId), "content": "One file, hello.txt, containing \"hello world\"."]]]])
        }

        let msg2 = "msg_\(MockClaude.randomId())"
        yield(["type": "stream_event", "parent_tool_use_id": nil, "event": ["type": "message_start", "message": ["id": .string(msg2)]]])
        try say(ok ? "\nAll done — that ran fine." : "\nUnderstood, I did not run it.")
        yield(["type": "result", "subtype": "success", "is_error": false, "result": "ok", "total_cost_usd": 0.0042, "num_turns": 2, "duration_ms": 1234, "session_id": .string(sid)])
    }
}
