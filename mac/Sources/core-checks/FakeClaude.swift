// A stand-in for the `claude` binary that speaks Claude Code's stream-json protocol, as captured from the
// official Agent SDK (0.3.331) driving it, so the turn code is tested with no network, no API key and no real
// binary. `core-checks --fake-claude <claude's flags>` runs it (the checks start their own binary that way).
// A port of the retired mac/Fixtures/fake-claude.mjs, which recorded mac/Fixtures/turns with the real SDK; the
// turn checks require the same results from this one.
//
// It is strict on purpose: a missing flag, a missing CLAUDE_CODE_ENTRYPOINT, a user message before
// `initialize`, or a host that never closes stdin after the result make it fail loudly (stderr + exit code).
// The scenario comes from the prompt: "crash", "slow" (runs until stopped), "edit" (Edit tool, usually denied),
// anything else: a Bash command, then a sub-agent.

import Foundation
import CharnessCore

enum FakeClaude {
    private static let lock = NSLock()
    private static var initialized = false
    private static var stdinClosed = false
    private static var answers: [String: (JSONObject) -> Void] = [:]

    private static func die(_ code: Int32, _ msg: String) -> Never {
        FileHandle.standardError.write(Data("fake-claude: \(msg)\n".utf8))
        quit(code)
    }

    /// _exit, not exit: exit() flushes stdio and would wait for the stdin lock readLine holds on the main thread.
    /// Nothing is buffered (output goes straight to the file handles).
    private static func quit(_ code: Int32) -> Never { _exit(code) }

    private static func out(_ o: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((o.jsonString() + "\n").utf8))
    }

    private static func sleep(_ ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }

    static func run(_ argv: [String]) -> Never {
        for f in ["--output-format", "stream-json", "--verbose", "--input-format", "--permission-prompt-tool=stdio", "--include-partial-messages"]
        where !argv.contains(f) {
            die(2, "missing argument \(f) (got: \(argv.joined(separator: " ")))")
        }
        if (ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] ?? "").isEmpty { die(2, "CLAUDE_CODE_ENTRYPOINT is not set") }
        func flag(_ name: String) -> String? {
            argv.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let model = flag("--model") ?? "fake-model"
        let mode = flag("--permission-mode") ?? "default"
        let session = flag("--resume") ?? "fake-session-1"

        while let line = readLine() {
            guard let m = (try? JSONValue.parse(line))?.objectValue else { die(4, "not JSON on stdin: \(line.prefix(80))") }
            let request = m["request"]?.objectValue
            if m["type"] == "control_request" && request?["subtype"] == "initialize" {
                lock.lock(); initialized = true; lock.unlock()
                out(["type": "control_response", "response": ["subtype": "success", "request_id": m["request_id"] ?? .null,
                                                              "response": ["commands": [], "models": []]]])
            } else if m["type"] == "control_request" {
                out(["type": "control_response", "response": ["subtype": "error", "request_id": m["request_id"] ?? .null,
                                                              "error": .string("fake-claude does not support \(request?["subtype"]?.stringValue ?? "undefined")")]])
            } else if m["type"] == "control_response" {
                let r = m["response"]?.objectValue ?? JSONObject()
                lock.lock(); let answer = answers[r["request_id"]?.stringValue ?? ""]; lock.unlock()
                answer?(r)
            } else if m["type"] == "user" {
                lock.lock(); let ready = initialized; lock.unlock()
                if !ready { die(4, "user message arrived before initialize") }
                let c = m["message"]?.objectValue?["content"]
                let prompt = c?.stringValue ?? (c?.arrayValue ?? []).map { $0.objectValue?["text"]?.stringValue ?? "" }.joined()
                Thread.detachNewThread { turn(prompt, model: model, mode: mode, session: session) }
            }
        }
        lock.lock(); stdinClosed = true; lock.unlock()
        sleep(50)
        quit(0)
    }

    private static func turn(_ prompt: String, model: String, mode: String, session: String) {
        let cwd = FileManager.default.currentDirectoryPath
        func parent(_ p: String?) -> JSONValue { p.map(JSONValue.string) ?? .null }
        func ev(_ event: JSONValue, _ p: String? = nil) {
            out(["type": "stream_event", "parent_tool_use_id": parent(p), "session_id": .string(session), "event": event])
        }
        func say(_ text: String) {
            let words = (try? NSRegularExpression(pattern: "\\S+\\s*"))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            for w in words {
                ev(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": .string((text as NSString).substring(with: w.range))]])
                sleep(2)
            }
        }
        func tool(_ id: String, _ name: String, _ input: JSONValue, _ p: String? = nil, _ msgId: String? = nil) {
            out(["type": "assistant", "parent_tool_use_id": parent(p), "session_id": .string(session),
                 "message": ["id": .string(msgId ?? "msg_\(id)"), "role": "assistant",
                             "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]]])
        }
        func result(_ id: String, _ content: JSONValue, _ isError: Bool = false, _ p: String? = nil) {
            out(["type": "user", "parent_tool_use_id": parent(p), "session_id": .string(session),
                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": content, "is_error": .bool(isError)]]]])
        }
        func ask(_ requestId: String, _ request: JSONValue) -> JSONObject {
            let done = DispatchSemaphore(value: 0)
            var got = JSONObject()
            lock.lock(); answers[requestId] = { got = $0; done.signal() }; lock.unlock()
            out(["type": "control_request", "request_id": .string(requestId), "request": request])
            done.wait()
            return got
        }

        out(["type": "system", "subtype": "init", "session_id": .string(session), "model": .string(model), "cwd": .string(cwd),
             "permissionMode": .string(mode), "tools": ["Bash", "Edit", "Read", "Glob", "Task"]])
        out(["type": "system", "subtype": "status", "status": "requesting", "session_id": .string(session)])
        ev(["type": "message_start", "message": ["id": "msg_1"]])
        ev(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking"]])
        sleep(20)
        ev(["type": "content_block_start", "index": 1, "content_block": ["type": "text"]])
        let intro = "Fake Claude (\(mode), \(model)). You said: \(prompt)\n\n"
        say(intro)
        let lower = prompt.lowercased()
        if lower.contains("crash") {
            FileHandle.standardError.write(Data("fatal: the fake model fell over\n".utf8))
            quit(3)
        }

        let edit = lower.contains("edit")
        let slow = lower.contains("slow")
        let name = edit ? "Edit" : "Bash"
        let input: JSONValue = edit
            ? ["file_path": .string("\(cwd)/README.md"), "old_string": "old", "new_string": "new"]
            : ["command": .string(slow ? "sleep 100" : "ls"), "description": "List files"]
        ev(["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_A", "name": .string(name)]])
        // the full assistant message repeats the streamed text; the host must not show it twice
        out(["type": "assistant", "parent_tool_use_id": .null, "session_id": .string(session),
             "message": ["id": "msg_1", "role": "assistant",
                         "content": [["type": "text", "text": .string(intro)], ["type": "tool_use", "id": "toolu_A", "name": .string(name), "input": input]]]])
        sleep(40)
        let r = ask("perm-A", ["subtype": "can_use_tool", "tool_name": .string(name), "input": input, "tool_use_id": "toolu_A",
                               "title": .string("Claude wants to use \(name)"), "description": .string(edit ? "Edit README.md" : "Run a command")])
        let d = r["response"]?.objectValue ?? JSONObject()
        let allowed = r["subtype"] == "success" && d["behavior"] == "allow" && d["toolUseID"] == "toolu_A"
        sleep(40)
        func progress(_ sec: Int) {
            out(["type": "tool_progress", "tool_use_id": "toolu_A", "tool_name": .string(name), "parent_tool_use_id": .null,
                 "elapsed_time_seconds": .number(Double(sec)), "session_id": .string(session)])
        }
        if allowed && slow {
            var sec = 1
            while true { progress(sec); sec += 1; sleep(100) }
        }
        if allowed {
            for sec in 1...2 { progress(sec); sleep(20) }
            result("toolu_A", [["type": "text", "text": "file-a\nfile-b"]])
        } else {
            let message = d["message"].flatMap { v -> JSONValue? in
                if case .string(let s) = v, s.isEmpty { return nil }
                if case .null = v { return nil }
                return v
            }
            result("toolu_A", message ?? "denied", true)
        }
        sleep(40)
        if allowed && !edit {
            tool("toolu_T", "Task", ["description": "Look around", "prompt": "Read the files", "subagent_type": "Explore"], nil, "msg_1")
            sleep(20)
            ev(["type": "content_block_start", "index": 0, "content_block": ["type": "text"]], "toolu_T")   // sub-agent chatter: ignored
            tool("toolu_S1", "Glob", ["pattern": "**/*"], "toolu_T"); sleep(20)
            result("toolu_S1", "file-a", false, "toolu_T"); sleep(20)
            tool("toolu_S2", "Read", ["file_path": .string("\(cwd)/file-a")], "toolu_T"); sleep(20)
            result("toolu_S2", "contents", false, "toolu_T"); sleep(20)
            result("toolu_T", "Two files."); sleep(40)
        }
        out(["type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10, "retry_delay_ms": 10, "error_status": 529,
             "error": "overloaded", "session_id": .string(session)])
        sleep(20)
        ev(["type": "message_start", "message": ["id": "msg_2"]])
        ev(["type": "content_block_start", "index": 0, "content_block": ["type": "text"]])
        let outro = allowed ? "All done — \"quotes\", ñ, 🚀." : "Understood, I did not do it."
        say(outro)
        out(["type": "assistant", "parent_tool_use_id": .null, "session_id": .string(session),
             "message": ["id": "msg_2", "role": "assistant", "content": [["type": "text", "text": .string(outro)]]]])
        out(["type": "result", "subtype": "success", "is_error": false, "result": .string(outro), "total_cost_usd": 0.0123, "num_turns": 3,
             "duration_ms": 4321, "session_id": .string(session)])
        Thread.detachNewThread {
            sleep(4000)
            lock.lock(); let closed = stdinClosed; lock.unlock()
            if !closed { die(5, "the host never closed stdin after the result") }
        }
    }
}
