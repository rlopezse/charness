// Folds one agent event into a thread's list of messages. The server uses it to save threads and the app's
// screens to show them live (ClientState). A port of apply() in the retired web UI's reduce.js, kept
// byte-compatible with the threads it saved (key order, fields missing from an event left out, string
// concatenation rules): `swift run core-checks` replays mac/Fixtures/reducer.json, recorded from the JavaScript.
//
// Messages:
//   {role:'user', text, files?: [{name, size}], ts}
//   {role:'assistant', blocks:[{type:'text', text} | {type:'tool', id, name, input, status, output?, ts?}], done?}
//     (a tool's ts, when it started, is Swift only; reduce.js didn't keep it)
//   {role:'system', text}
//   {role:'system', kind:'compact', text}   (Swift only: where Claude Code replaced the history with a summary)

public enum Reducer {
    /// Applies one event to `msgs`. Returns the index of the message that changed, or -1 if none did.
    @discardableResult
    public static func apply(_ msgs: inout [JSONValue], _ ev: JSONValue) -> Int {
        let e = ev.objectValue ?? JSONObject()

        switch e["t"] ?? .null {
        case .string("user"):
            var m: JSONObject = ["role": "user"]
            if let v = e["text"] { m["text"] = v }
            if lengthIsTruthy(e["files"]) { m["files"] = e["files"] }
            if let v = e["ts"] { m["ts"] = v }
            msgs.append(.object(m))
            return msgs.count - 1

        case .string("delta"):
            let i = assistantIndex(&msgs)
            msgs[i].modifyObject { m in
                m.modify("blocks") { blocks in
                    blocks.modifyArray { blocks in
                        if let last = blocks.indices.last, blocks[last].objectValue?["type"] == "text" {
                            blocks[last].modifyObject { b in
                                // b.text += ev.text, appending in place (a long answer arrives one word at a time)
                                let appended = b.modify("text") { v -> Void in
                                    if case .string(var s) = v, case .string(let add)? = e["text"] {
                                        v = .null      // drop our reference so `s` isn't copied when it grows
                                        s += add
                                        v = .string(s)
                                    } else {
                                        v = .string(jsConcat(v, e["text"]))
                                    }
                                }
                                if appended == nil { b["text"] = .string(jsConcat(nil, e["text"])) }
                            }
                        } else {
                            var b: JSONObject = ["type": "text"]
                            if let v = e["text"] { b["text"] = v }
                            blocks.append(.object(b))
                        }
                    }
                }
            }
            return msgs.count - 1

        case .string("tool_use"):
            let i = assistantIndex(&msgs)
            msgs[i].modifyObject { m in
                m.modify("blocks") { blocks in
                    blocks.modifyArray { blocks in
                        let known = blocks.contains { b in
                            let o = b.objectValue
                            return o?["type"] == "tool" && strictEqual(o?["id"], e["id"])
                        }
                        if !known {
                            var b: JSONObject = ["type": "tool"]
                            if let v = e["id"] { b["id"] = v }
                            if let v = e["name"] { b["name"] = v }
                            if let v = e["input"] { b["input"] = v }
                            b["status"] = "running"
                            if let v = e["ts"] { b["ts"] = v }   // Swift only: when it started (the work log shows it)
                            blocks.append(.object(b))
                        }
                    }
                }
            }
            return msgs.count - 1

        case .string("tool_result"):
            guard let (i, j) = findTool(msgs, e["id"]) else { return -1 }
            editBlock(&msgs, i, j) { b in
                b["output"] = e["output"]   // a missing output leaves the field out, as `= undefined` does in JSON
                if b["status"] != "denied" { b["status"] = JS.truthy(e["isError"]) ? "error" : "ok" }
            }
            return i

        case .string("tool_denied"):
            guard let (i, j) = findTool(msgs, e["id"]) else { return -1 }
            editBlock(&msgs, i, j) { b in b["status"] = "denied" }
            return i

        case .string("end"):
            guard msgs.last?.objectValue?["role"] == "assistant" else { return -1 }
            var done = JSONObject()
            if let v = e["cost"] { done["cost"] = v }
            if let v = e["turns"] { done["turns"] = v }
            if let v = e["ms"] { done["ms"] = v }
            msgs[msgs.count - 1].modifyObject { m in m["done"] = .object(done) }
            return msgs.count - 1

        case .string("compacted"):
            msgs.append(["role": "system", "kind": "compact", "text": .string(compactNote(e))])
            return msgs.count - 1

        case .string("error"):
            var m: JSONObject = ["role": "system"]
            if let v = e["text"] { m["text"] = v }
            msgs.append(.object(m))
            return msgs.count - 1

        default:
            return -1
        }
    }

    /// The note left in a thread where it was compacted.
    public static func compactNote(_ e: JSONObject) -> String {
        var size = ""
        if let n = e["preTokens"]?.doubleValue, n > 0 {
            size = n >= 1000 ? " (it was about \(Int((n / 1000).rounded()))k tokens)" : " (it was \(Int(n)) tokens)"
        }
        return e["trigger"]?.stringValue == "auto"
            ? "Conversation compacted automatically\(size). Claude continues from a summary of what came before."
            : "Conversation compacted\(size). Claude continues from a summary of what came before."
    }

    // The last message if it is the assistant's, else a new empty assistant message (asst() in the JS).
    private static func assistantIndex(_ msgs: inout [JSONValue]) -> Int {
        if msgs.last?.objectValue?["role"] != "assistant" { msgs.append(["role": "assistant", "blocks": []]) }
        return msgs.count - 1
    }

    // The newest assistant message holding a tool block with this id (findTool() in the JS).
    private static func findTool(_ msgs: [JSONValue], _ id: JSONValue?) -> (Int, Int)? {
        for i in msgs.indices.reversed() {
            guard let m = msgs[i].objectValue, m["role"] == "assistant", let blocks = m["blocks"]?.arrayValue else { continue }
            if let j = blocks.firstIndex(where: { b in
                let o = b.objectValue
                return o?["type"] == "tool" && strictEqual(o?["id"], id)
            }) { return (i, j) }
        }
        return nil
    }

    private static func editBlock(_ msgs: inout [JSONValue], _ i: Int, _ j: Int, _ change: (inout JSONObject) -> Void) {
        msgs[i].modifyObject { m in
            m.modify("blocks") { blocks in
                blocks.modifyArray { blocks in blocks[j].modifyObject(change) }
            }
        }
    }

    // `ev.files?.length` is truthy: a non-empty array (or string).
    private static func lengthIsTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .some(.array(let a)): return !a.isEmpty
        case .some(.string(let s)): return !s.isEmpty
        default: return false
        }
    }

    // JavaScript ===, for the values events carry. A missing value equals a missing value (undefined === undefined).
    private static func strictEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        switch (a, b) {
        case (.none, .none), (.some(.null), .some(.null)): return true
        case (.some(.string(let x)), .some(.string(let y))): return x == y
        case (.some(.number(let x)), .some(.number(let y))): return x == y
        case (.some(.bool(let x)), .some(.bool(let y))): return x == y
        default: return false   // objects and arrays are only === to themselves
        }
    }

    // a + b where one side is a string (how JavaScript turns the other side into text).
    private static func jsConcat(_ a: JSONValue?, _ b: JSONValue?) -> String {
        func text(_ v: JSONValue?) -> String {
            switch v {
            case .none: return "undefined"
            case .some(.null): return "null"
            default: return JS.string(v)
            }
        }
        return text(a) + text(b)
    }
}
