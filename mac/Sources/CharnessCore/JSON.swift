// A small JSON reader/writer that behaves like JavaScript's JSON.parse / JSON.stringify.
//
// Why not Foundation's JSONSerialization or Codable: they don't keep object key order, they format numbers
// differently from JavaScript, and older macOS versions blur booleans and numbers. While Node and Swift share
// ~/.charness, the Swift side must rewrite Node's files exactly, so this mirrors JS behaviour on purpose
// (checked against real JavaScript output in mac/Fixtures/js-format.tsv by `swift run core-checks`).
//
// One known difference: a lone UTF-16 surrogate escape ("\ud800") becomes U+FFFD, because Swift strings
// can't hold one. JavaScript keeps it. Charness never writes those.

/// A JSON value. Objects keep their key order.
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }
}

/// A JSON object that keeps insertion order. Setting an existing key keeps its position (like JS);
/// setting a key to nil removes it. Equality ignores order, like comparing two JS objects field by field.
public struct JSONObject: Equatable {
    public private(set) var entries: [(key: String, value: JSONValue)] = []

    public init() {}
    public init(_ pairs: [(String, JSONValue)]) { for (k, v) in pairs { self[k] = v } }

    public var keys: [String] { entries.map { $0.key } }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let v = newValue { entries[i].value = v } else { entries.remove(at: i) }
            } else if let v = newValue {
                entries.append((key: key, value: v))
            }
        }
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        guard a.entries.count == b.entries.count else { return false }
        for (k, v) in a.entries where b[k] != v { return false }
        return true
    }
}

// Literals, so code and checks can write  ["id": "abc", "cost": 0, "sessionId": nil]
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }
}

// MARK: - parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "invalid JSON at byte \(offset): \(reason)" }
}

extension JSONValue {
    /// Parses like JSON.parse. Input is UTF-8; invalid UTF-8 becomes U+FFFD, as when Node reads a file as 'utf8'.
    public static func parse<Bytes: Collection>(_ bytes: Bytes) throws -> JSONValue where Bytes.Element == UInt8 {
        var p = JSONParser(Array(bytes))
        return try p.document()
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Array(text.utf8)) }
}

private struct JSONParser {
    let b: [UInt8]
    var i = 0
    var depth = 0
    static let maxDepth = 512   // deep enough for any real file; stops a hostile file from overflowing the stack

    init(_ bytes: [UInt8]) { b = bytes }

    func fail(_ reason: String) -> JSONParseError { JSONParseError(offset: i, reason: reason) }

    mutating func document() throws -> JSONValue {
        skipSpace()
        let v = try value()
        skipSpace()
        if i != b.count { throw fail("unexpected content after the value") }
        return v
    }

    mutating func skipSpace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard i < b.count else { throw fail("unexpected end of input") }
        switch b[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: throw fail("unexpected character")
        }
    }

    mutating func literal(_ word: String) throws {
        for c in word.utf8 {
            guard i < b.count, b[i] == c else { throw fail("expected \(word)") }
            i += 1
        }
    }

    mutating func enter() throws {
        depth += 1
        if depth > JSONParser.maxDepth { throw fail("nested too deeply") }
    }

    mutating func object() throws -> JSONValue {
        try enter(); defer { depth -= 1 }
        i += 1
        var obj = JSONObject()
        skipSpace()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
        while true {
            skipSpace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a string key") }
            let key = try string()
            skipSpace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            i += 1
            skipSpace()
            obj[key] = try value()   // duplicate key: last value wins, first position kept (as in JS)
            skipSpace()
            guard i < b.count else { throw fail("unexpected end of input") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func array() throws -> JSONValue {
        try enter(); defer { depth -= 1 }
        i += 1
        var items: [JSONValue] = []
        skipSpace()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipSpace()
            items.append(try value())
            skipSpace()
            guard i < b.count else { throw fail("unexpected end of input") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func number() throws -> JSONValue {
        let start = i
        func digits(_ p: inout JSONParser) -> Int {
            let s = p.i
            while p.i < p.b.count, p.b[p.i] >= UInt8(ascii: "0"), p.b[p.i] <= UInt8(ascii: "9") { p.i += 1 }
            return p.i - s
        }
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail("bad number") }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if digits(&self) == 0 {
            throw fail("bad number")
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            if digits(&self) == 0 { throw fail("bad number: digits expected after '.'") }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            if digits(&self) == 0 { throw fail("bad number: digits expected in exponent") }
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        guard let d = Double(text) else { throw JSONParseError(offset: start, reason: "bad number") }
        return .number(d)   // like JS: too large becomes Infinity (written back as null)
    }

    mutating func string() throws -> String {
        i += 1   // opening quote
        var out: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw fail("control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw fail("unterminated string") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar) {
                    // a high surrogate only makes a character together with a following \uDC00-\uDFFF
                    if i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                            scalar = 0xFFFD
                        }
                    } else {
                        scalar = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    scalar = 0xFFFD
                }
                out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar)!)).utf8))
            default:
                throw fail("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw fail("bad \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: throw fail("bad \\u escape")
            }
            v = v << 4 | UInt32(d)
            i += 1
        }
        return v
    }
}

// MARK: - writing

extension JSONValue {
    /// Exactly what JSON.stringify(value) writes, or JSON.stringify(value, null, 2) when `pretty` is true.
    public func jsonString(pretty: Bool = false) -> String {
        var out = ""
        JSONWriter.write(self, into: &out, indent: pretty ? "" : nil)
        return out
    }

    /// JavaScript's Number.prototype.toString(), as JSON.stringify uses it. Non-finite numbers become "null".
    public static func jsNumber(_ d: Double) -> String { JSONWriter.number(d) }
}

private enum JSONWriter {
    static func write(_ v: JSONValue, into out: inout String, indent: String?) {
        switch v {
        case .null: out += "null"
        case .bool(let x): out += x ? "true" : "false"
        case .number(let d): out += number(d)
        case .string(let s): quote(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            let inner = indent.map { $0 + "  " }
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                if let inner = inner { out += "\n" + inner }
                write(item, into: &out, indent: inner)
            }
            if let indent = indent { out += "\n" + indent }
            out += "]"
        case .object(let obj):
            if obj.isEmpty { out += "{}"; return }
            out += "{"
            let inner = indent.map { $0 + "  " }
            for (n, entry) in jsOrder(obj).enumerated() {
                if n > 0 { out += "," }
                if let inner = inner { out += "\n" + inner }
                quote(entry.key, into: &out)
                out += inner == nil ? ":" : ": "
                write(entry.value, into: &out, indent: inner)
            }
            if let indent = indent { out += "\n" + indent }
            out += "}"
        }
    }

    // JS objects list integer-like keys ("0", "1", "10"...) first, in numeric order, then the rest in insertion order.
    static func jsOrder(_ obj: JSONObject) -> [(key: String, value: JSONValue)] {
        let indexed = obj.entries.filter { arrayIndex($0.key) != nil }
        if indexed.isEmpty { return obj.entries }
        let rest = obj.entries.filter { arrayIndex($0.key) == nil }
        return indexed.sorted { arrayIndex($0.key)! < arrayIndex($1.key)! } + rest
    }

    static func arrayIndex(_ key: String) -> UInt64? {
        guard let first = key.utf8.first, key.utf8.count <= 10,
              key.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              first != UInt8(ascii: "0") || key.utf8.count == 1,
              let n = UInt64(key), n < 4_294_967_295 else { return nil }
        return n
    }

    static func quote(_ s: String, into out: inout String) {
        let hex = Array("0123456789abcdef")
        out += "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20:
                out += "\\u00"
                out.append(hex[Int(u.value >> 4)])
                out.append(hex[Int(u.value & 0xF)])
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    // ECMAScript Number::toString. Swift's description already gives the shortest digits that round-trip
    // (as JS does); this only re-lays them out the way JS does (e.g. 1.5e-05 -> 0.000015, 1e+20 -> 100000...).
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == 0 { return "0" }   // includes -0, which JS writes as "0"
        let text = "\(Swift.abs(d))"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var digits = ""
        var pointAt = 0   // the decimal point sits after this many digits
        if let dot = mantissa.firstIndex(of: ".") {
            digits = String(mantissa[..<dot]) + String(mantissa[mantissa.index(after: dot)...])
            pointAt = mantissa.distance(from: mantissa.startIndex, to: dot)
        } else {
            digits = String(mantissa)
            pointAt = digits.count
        }
        while digits.first == "0" { digits.removeFirst(); pointAt -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let n = pointAt + exponent   // value = 0.<digits> x 10^n
        var s: String
        if k <= n && n <= 21 {
            s = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            s = String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        } else if -6 < n && n <= 0 {
            s = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            s = String(digits.prefix(1))
            if k > 1 { s += "." + String(digits.dropFirst()) }
            s += "e" + sign + String(Swift.abs(e))
        }
        return d < 0 ? "-" + s : s
    }
}
