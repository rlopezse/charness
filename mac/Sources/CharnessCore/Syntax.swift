// Syntax colors for code blocks, after T3 Code (which colors them with Shiki and the Pierre themes): a small
// hand-written tokenizer for JavaScript / TypeScript, JSON, HTML (with the code in its <script> and <style>), CSS
// and SQL, sorting text into the categories those themes color. It is not a parser: it only has to color typical
// snippets well, and never lose, add or reorder a character (core-checks require the tokens to join back into the
// input exactly, for any input). Other languages stay plain. The colors are in Theme.swift.

import Foundation

public enum SyntaxKind: String, CaseIterable {
    case plain, comment, string, number, keyword, function, type, variable
    /// `this`, `super`.
    case special
    case `operator`, punctuation
    /// HTML tag names, CSS element selectors, JSON keys, CSS units, HTML entities.
    case tag
    /// HTML attribute names, CSS class selectors.
    case attribute
    /// CSS property names.
    case property
    /// CSS values (`red`, `flex`, `auto`).
    case value
    case regexp
}

public struct SyntaxToken: Equatable {
    public var text: String
    public var kind: SyntaxKind
    public init(text: String, kind: SyntaxKind) {
        self.text = text
        self.kind = kind
    }
}

public enum Syntax {
    public enum Language { case js, ts, json, html, css, sql }

    /// The language a code fence names ("```tsx"), if it's one of these.
    public static func language(_ name: String) -> Language? {
        switch name.lowercased() {
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return .js
        case "ts", "typescript", "tsx", "mts", "cts": return .ts
        case "json", "jsonc", "json5": return .json
        case "html", "htm", "xhtml", "xml", "svg": return .html
        case "css", "scss", "less": return .css
        case "sql", "mysql", "mariadb", "postgres", "postgresql", "psql", "pgsql", "sqlite", "plsql", "tsql": return .sql
        default: return nil
        }
    }

    /// The code as colored runs, neighbours of the same kind merged. A language it doesn't know: one plain run.
    public static func highlight(_ code: String, language name: String) -> [SyntaxToken] {
        guard !code.isEmpty else { return [] }
        guard let lang = language(name) else { return [SyntaxToken(text: code, kind: .plain)] }
        var t = Tokenizer(code)
        let end = t.s.count
        switch lang {
        case .js: t.js(0, end, ts: false, json: false)
        case .ts: t.js(0, end, ts: true, json: false)
        case .json: t.js(0, end, ts: false, json: true)
        case .html: t.html(0, end)
        case .css: t.css(0, end)
        case .sql: t.sql(0, end)
        }
        return t.tokens()
    }
}

private struct Tokenizer {
    let s: [Unicode.Scalar]
    /// (start, end, kind), in order.
    var spans: [(Int, Int, SyntaxKind)] = []

    init(_ code: String) { s = Array(code.unicodeScalars) }

    mutating func add(_ a: Int, _ b: Int, _ k: SyntaxKind) { if b > a { spans.append((a, b, k)) } }

    func text(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(s[a..<b])) }

    /// The spans as tokens. Gaps become plain and overlaps are cut, so the tokens always cover the input exactly once.
    func tokens() -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var at = 0
        func push(_ a: Int, _ b: Int, _ k: SyntaxKind) {
            guard b > a else { return }
            let t = text(a, b)
            if let last = out.last, last.kind == k { out[out.count - 1].text += t } else { out.append(SyntaxToken(text: t, kind: k)) }
        }
        for (a0, b, k) in spans {
            let a = max(a0, at)
            guard b > a else { continue }
            push(at, a, .plain)
            push(a, b, k)
            at = b
        }
        push(at, s.count, .plain)
        return out
    }

    // MARK: characters

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    static func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || c.properties.isAlphabetic }
    static func isIdentPart(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }
    static func isCSSIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "-" || c.properties.isAlphabetic }
    static func isCSSIdent(_ c: Unicode.Scalar) -> Bool { isCSSIdentStart(c) || isDigit(c) }
    static func isLetter(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic }

    func has(_ word: String, at i: Int, end: Int) -> Bool {
        var j = i
        for c in word.unicodeScalars {
            guard j < end, s[j] == c else { return false }
            j += 1
        }
        return true
    }

    func find(_ word: String, from i: Int, end: Int, ignoringCase: Bool = false) -> Int? {
        let w = Array((ignoringCase ? word.lowercased() : word).unicodeScalars)
        guard !w.isEmpty, end - i >= w.count else { return nil }
        var j = i
        while j + w.count <= end {
            var k = 0
            while k < w.count {
                let c = ignoringCase ? (String(s[j + k]).lowercased().unicodeScalars.first ?? s[j + k]) : s[j + k]
                if c != w[k] { break }
                k += 1
            }
            if k == w.count { return j }
            j += 1
        }
        return nil
    }

    /// Where a string that opens at `i` ends (after its closing quote; at the line's end if it isn't closed and
    /// can't span lines; at `end` otherwise).
    func stringEnd(_ i: Int, _ end: Int, multiline: Bool) -> Int {
        let quote = s[i]
        var j = i + 1
        while j < end {
            let c = s[j]
            if c == "\\" { j += 2; continue }
            if c == quote { return j + 1 }
            if !multiline && c == "\n" { return j }
            j += 1
        }
        return end
    }

    func nextNonSpace(_ i: Int, _ end: Int) -> Unicode.Scalar? {
        var j = i
        while j < end && Tokenizer.isSpace(s[j]) { j += 1 }
        return j < end ? s[j] : nil
    }

    // MARK: JavaScript, TypeScript, JSON

    static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let",
        "new", "of", "return", "static", "switch", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
    ]
    static let tsKeywords: Set<String> = [
        "abstract", "as", "declare", "enum", "implements", "infer", "interface", "is", "keyof", "module", "namespace",
        "private", "protected", "public", "readonly", "satisfies", "type",
    ]
    static let tsTypes: Set<String> = ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown"]
    static let jsConstants: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity"]
    /// Keywords after which a "/" starts a regular expression rather than dividing.
    static let beforeRegex: Set<String> = ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield", "await"]
    static let operators = Set("=+-*/%<>!&|^~?".unicodeScalars)
    static let jsPunctuation = Set("()[]{},;.:".unicodeScalars)

    mutating func js(_ start: Int, _ end: Int, ts: Bool, json: Bool) {
        var i = start
        var prevKind: SyntaxKind?
        var prevText = ""
        while i < end {
            let c = s[i]
            let a = i
            if Tokenizer.isSpace(c) {
                while i < end && Tokenizer.isSpace(s[i]) { i += 1 }
                add(a, i, .plain)
                continue
            }
            var kind = SyntaxKind.plain
            let next: Unicode.Scalar? = i + 1 < end ? s[i + 1] : nil
            if c == "/" && next == "/" {
                while i < end && s[i] != "\n" { i += 1 }
                kind = .comment
            } else if c == "/" && next == "*" {
                i = find("*/", from: i + 2, end: end).map { $0 + 2 } ?? end
                kind = .comment
            } else if c == "\"" || c == "'" || c == "`" {
                i = stringEnd(i, end, multiline: c == "`")
                kind = .string
                if json && nextNonSpace(i, end) == ":" { kind = .tag }   // a key
            } else if Tokenizer.isDigit(c) || (c == "." && next.map(Tokenizer.isDigit) == true) {
                i += 1
                while i < end, Tokenizer.isIdentPart(s[i]) || (s[i] == "." && i + 1 < end && Tokenizer.isDigit(s[i + 1])) { i += 1 }
                kind = .number
            } else if Tokenizer.isIdentStart(c) {
                while i < end && Tokenizer.isIdentPart(s[i]) { i += 1 }
                let word = text(a, i)
                if json {
                    kind = Tokenizer.jsConstants.contains(word) ? .operator : .plain
                } else if Tokenizer.jsConstants.contains(word) {
                    kind = .number
                } else if word == "this" || word == "super" {
                    kind = .special
                } else if prevText == "." {
                    kind = nextNonSpace(i, end) == "(" ? .function : .variable   // a property or method, even "default"
                } else if Tokenizer.jsKeywords.contains(word) || (ts && Tokenizer.tsKeywords.contains(word)) {
                    kind = .keyword
                } else if ts && Tokenizer.tsTypes.contains(word) {
                    kind = .type
                } else if word.unicodeScalars.first?.properties.isUppercase == true {
                    kind = .type
                } else if nextNonSpace(i, end) == "(" {
                    kind = .function
                } else {
                    kind = .variable
                }
            } else if c == "/", regexAllowed(prevKind, prevText), let e = regexEnd(i, end) {
                i = e
                kind = .regexp
            } else if c == "=" && next == ">" {
                i += 2
                kind = .keyword   // => (the Pierre themes color it as a keyword)
            } else if Tokenizer.operators.contains(c) {
                i += 1
                kind = .operator
            } else if Tokenizer.jsPunctuation.contains(c) {
                i += 1
                kind = .punctuation
            } else {
                i += 1
            }
            add(a, i, kind)
            prevKind = kind
            prevText = text(a, i)
        }
    }

    func regexAllowed(_ prev: SyntaxKind?, _ prevText: String) -> Bool {
        guard let prev else { return true }
        switch prev {
        case .operator: return true
        case .punctuation: return prevText != ")" && prevText != "]" && prevText != "}"
        case .keyword: return Tokenizer.beforeRegex.contains(prevText)
        default: return false
        }
    }

    /// The end of a regular expression literal opening at `i` (after its flags), or nil if this "/" can't be one.
    func regexEnd(_ i: Int, _ end: Int) -> Int? {
        var j = i + 1
        var inClass = false
        while j < end {
            let c = s[j]
            if c == "\n" { return nil }
            if c == "\\" { j += 2; continue }
            if c == "[" { inClass = true }
            else if c == "]" { inClass = false }
            else if c == "/" && !inClass {
                j += 1
                while j < end && Tokenizer.isIdentPart(s[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    // MARK: CSS

    private enum CSSMode { case selector, property, value, atRule }

    mutating func css(_ start: Int, _ end: Int) {
        var mode = CSSMode.selector
        var statementStart = true
        var depth = 0
        var inBrackets = false
        var i = start
        while i < end {
            let c = s[i]
            let a = i
            if Tokenizer.isSpace(c) {
                while i < end && Tokenizer.isSpace(s[i]) { i += 1 }
                add(a, i, .plain)
                continue
            }
            if c == "/" && i + 1 < end && s[i + 1] == "*" {
                i = find("*/", from: i + 2, end: end).map { $0 + 2 } ?? end
                add(a, i, .comment)
                continue
            }
            if statementStart {
                statementStart = false
                if c == "@" {
                    mode = .atRule
                } else {
                    // a declaration ("color: red;") ends at ; or }, a selector ("a:hover {") opens a block
                    var decl = depth > 0
                    var j = i
                    while j < end {
                        let d = s[j]
                        if d == "{" { decl = false; break }
                        if d == ";" || d == "}" { break }
                        j += 1
                    }
                    mode = decl ? .property : .selector
                }
            }
            var kind = SyntaxKind.plain
            let next: Unicode.Scalar? = i + 1 < end ? s[i + 1] : nil
            switch c {
            case "\"", "'":
                i = stringEnd(i, end, multiline: false)
                kind = .string
            case "{":
                i += 1; kind = .punctuation
                depth += 1; statementStart = true; mode = .selector
            case "}":
                i += 1; kind = .punctuation
                depth = max(0, depth - 1); statementStart = true; mode = .selector
            case ";":
                i += 1; kind = .punctuation
                statementStart = true
            case ":":
                i += 1
                if mode == .property {
                    kind = .punctuation
                    mode = .value
                } else if mode == .selector {   // :hover, ::before
                    if i < end && s[i] == ":" { i += 1 }
                    while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                    kind = .operator
                } else {
                    kind = .punctuation
                }
            case "@":
                i += 1
                while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                kind = .keyword
            case "#":
                i += 1
                while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                kind = mode == .selector ? .function : .operator   // #id, or a color like #fff
            case "!" where mode == .value:
                i += 1
                while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                kind = .keyword   // !important
            case "[", "]":
                i += 1; kind = .punctuation
                inBrackets = c == "["
            default:
                let startsNumber = Tokenizer.isDigit(c)
                    || (c == "." && next.map(Tokenizer.isDigit) == true)
                    || ((c == "-" || c == "+") && mode != .selector && next.map { Tokenizer.isDigit($0) || $0 == "." } == true)
                if c == "." && mode == .selector && next.map(Tokenizer.isCSSIdentStart) == true {
                    i += 1
                    while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                    kind = .attribute   // .class
                } else if startsNumber {
                    i += 1
                    while i < end && (Tokenizer.isDigit(s[i]) || s[i] == ".") { i += 1 }
                    add(a, i, .number)
                    let u = i
                    while i < end && (Tokenizer.isLetter(s[i]) || s[i] == "%") { i += 1 }
                    add(u, i, .tag)   // the unit
                    continue
                } else if Tokenizer.isCSSIdentStart(c) {
                    i += 1
                    while i < end && Tokenizer.isCSSIdent(s[i]) { i += 1 }
                    switch mode {
                    case .property: kind = .property
                    case .selector: kind = inBrackets ? .attribute : .tag
                    case .value, .atRule: kind = i < end && s[i] == "(" ? .function : .value
                    }
                } else if mode == .selector && (c == ">" || c == "+" || c == "~" || c == "*") {
                    i += 1; kind = .operator
                } else {
                    i += 1
                    kind = "(),&=|^$".unicodeScalars.contains(c) ? .punctuation : .plain
                }
            }
            add(a, i, kind)
        }
    }

    // MARK: SQL

    static let sqlKeywords: Set<String> = [
        "add", "all", "alter", "and", "any", "as", "asc", "auto_increment", "autoincrement", "begin", "between", "by",
        "cascade", "case", "check", "column", "commit", "conflict", "constraint", "create", "cross", "database", "declare",
        "default", "delete", "desc", "distinct", "do", "drop", "else", "end", "engine", "except", "exec", "execute",
        "exists", "explain", "foreign", "from", "full", "function", "grant", "group", "having", "if", "ilike", "in",
        "index", "inner", "insert", "intersect", "into", "is", "join", "key", "language", "left", "like", "limit",
        "natural", "not", "nothing", "offset", "on", "or", "order", "outer", "over", "partition", "primary", "procedure",
        "references", "replace", "return", "returning", "returns", "revoke", "right", "rollback", "schema", "select",
        "set", "show", "table", "temp", "temporary", "then", "transaction", "trigger", "truncate", "union", "unique",
        "update", "use", "using", "values", "view", "when", "where", "window", "with",
    ]
    static let sqlTypes: Set<String> = [
        "bigint", "bigserial", "binary", "blob", "bool", "boolean", "bytea", "char", "character", "date", "datetime",
        "decimal", "double", "enum", "float", "int", "integer", "interval", "json", "jsonb", "longtext", "mediumint",
        "mediumtext", "money", "numeric", "precision", "real", "serial", "smallint", "text", "time", "timestamp",
        "timestamptz", "tinyint", "tinytext", "unsigned", "uuid", "varbinary", "varchar", "varying",
    ]
    static let sqlConstants: Set<String> = ["null", "true", "false"]
    /// Words after which a name followed by "(" is a table (CREATE TABLE t (…), INSERT INTO t (…)), not a function.
    static let sqlBeforeName: Set<String> = ["table", "into", "exists", "view", "references", "index", "on", "update", "join", "from"]

    mutating func sql(_ start: Int, _ end: Int) {
        var i = start
        var prevText = ""
        while i < end {
            let c = s[i]
            let a = i
            if Tokenizer.isSpace(c) {
                while i < end && Tokenizer.isSpace(s[i]) { i += 1 }
                add(a, i, .plain)
                continue
            }
            var kind = SyntaxKind.plain
            let next: Unicode.Scalar? = i + 1 < end ? s[i + 1] : nil
            if (c == "-" && next == "-") || c == "#" && i == start {
                while i < end && s[i] != "\n" { i += 1 }
                kind = .comment
            } else if c == "/" && next == "*" {
                i = find("*/", from: i + 2, end: end).map { $0 + 2 } ?? end
                kind = .comment
            } else if c == "'" || c == "\"" || c == "`" {
                i = stringEnd(i, end, multiline: true)
                kind = .string
            } else if Tokenizer.isDigit(c) || (c == "." && next.map(Tokenizer.isDigit) == true) {
                i += 1
                while i < end, Tokenizer.isIdentPart(s[i]) || (s[i] == "." && i + 1 < end && Tokenizer.isDigit(s[i + 1])) { i += 1 }
                kind = .number
            } else if (c == "?" ) || ((c == "$" || c == ":" || c == "@") && next.map { Tokenizer.isIdentPart($0) } == true && !(c == ":" && prevText == ":")) {
                // query parameters: ?  $1  :name  @var (but not the second colon of a ::cast)
                i += 1
                while i < end && Tokenizer.isIdentPart(s[i]) { i += 1 }
                kind = .variable
            } else if Tokenizer.isIdentStart(c) {
                while i < end && Tokenizer.isIdentPart(s[i]) { i += 1 }
                let word = text(a, i).lowercased()
                if prevText == "." { kind = .plain }   // table.column
                else if Tokenizer.sqlConstants.contains(word) { kind = .number }
                else if Tokenizer.sqlTypes.contains(word) { kind = .type }
                else if Tokenizer.sqlKeywords.contains(word) { kind = .keyword }
                else if nextNonSpace(i, end) == "(" && !Tokenizer.sqlBeforeName.contains(prevText.lowercased()) { kind = .function }
            } else if "=<>!+-*/%|&^~".unicodeScalars.contains(c) {
                i += 1
                kind = .operator
            } else if "(),;.:[]".unicodeScalars.contains(c) {
                i += 1
                kind = .punctuation
            } else {
                i += 1
            }
            add(a, i, kind)
            prevText = text(a, i)
        }
    }

    // MARK: HTML

    mutating func html(_ start: Int, _ end: Int) {
        var i = start
        var textStart = start
        while i < end {
            let c = s[i]
            if c == "<" {
                if has("<!--", at: i, end: end) {
                    add(textStart, i, .plain)
                    let e = find("-->", from: i + 4, end: end).map { $0 + 3 } ?? end
                    add(i, e, .comment)
                    i = e
                    textStart = i
                    continue
                }
                if i + 1 < end, Tokenizer.isLetter(s[i + 1]) || s[i + 1] == "/" || s[i + 1] == "!" || s[i + 1] == "?" {
                    add(textStart, i, .plain)
                    i = tag(i, end)
                    textStart = i
                    continue
                }
            } else if c == "&" {   // &amp; &#39;
                var j = i + 1
                while j < end && j - i <= 10 && (Tokenizer.isIdentPart(s[j]) || s[j] == "#") { j += 1 }
                if j < end && s[j] == ";" && j > i + 1 {
                    add(textStart, i, .plain)
                    add(i, j + 1, .tag)
                    i = j + 1
                    textStart = i
                    continue
                }
            }
            i += 1
        }
        add(textStart, end, .plain)
    }

    /// One tag starting at "<", and after an opening <script> or <style>, the code in it (colored as JavaScript or
    /// CSS) up to its closing tag. Returns where the text after it starts.
    mutating func tag(_ start: Int, _ end: Int) -> Int {
        var i = start + 1
        let marker = s[i]
        if marker == "/" || marker == "!" || marker == "?" { i += 1 }
        add(start, i, .punctuation)
        let n = i
        while i < end && (Tokenizer.isIdentPart(s[i]) || s[i] == "-" || s[i] == ":") { i += 1 }
        let name = text(n, i).lowercased()
        add(n, i, marker == "!" ? .keyword : .tag)
        var selfClosing = false
        while i < end {
            let c = s[i]
            if c == ">" { add(i, i + 1, .punctuation); i += 1; break }
            if c == "/" && i + 1 < end && s[i + 1] == ">" { add(i, i + 2, .punctuation); i += 2; selfClosing = true; break }
            if c == "<" { break }   // an unclosed tag: the text scanner takes over
            if Tokenizer.isSpace(c) {
                let a = i
                while i < end && Tokenizer.isSpace(s[i]) { i += 1 }
                add(a, i, .plain)
                continue
            }
            if c == "\"" || c == "'" {
                let a = i
                i = stringEnd(i, end, multiline: true)
                add(a, i, .string)
                continue
            }
            if c == "=" {
                add(i, i + 1, .punctuation)
                i += 1
                if i < end, !Tokenizer.isSpace(s[i]), s[i] != "\"", s[i] != "'", s[i] != ">" {   // an unquoted value
                    let a = i
                    while i < end && !Tokenizer.isSpace(s[i]) && s[i] != ">" { i += 1 }
                    add(a, i, .string)
                }
                continue
            }
            let a = i
            while i < end, !Tokenizer.isSpace(s[i]), !"=>/\"'<".unicodeScalars.contains(s[i]) { i += 1 }
            if i == a { i += 1 }   // a lone "/"
            add(a, i, .attribute)
        }
        if marker != "/" && marker != "!" && !selfClosing && (name == "script" || name == "style") {
            let close = find("</" + name, from: i, end: end, ignoringCase: true) ?? end
            if name == "script" { js(i, close, ts: false, json: false) } else { css(i, close) }
            return close
        }
        return i
    }
}
