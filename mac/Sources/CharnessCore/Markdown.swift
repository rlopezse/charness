// Markdown for the native screens: blocks and styled runs (headings, paragraphs, nested lists, quotes, code
// fences, tables, rules; inline code, bold, italic, strike-through, and links only for http(s) and mailto).
// Bare http(s) addresses become links too (also a `code span` that is just an address); linkify() does the same
// for plain text such as command output. Nothing here is ever interpreted as markup: the views draw text runs.
// A port of the retired web UI's md.js: core-checks requires the same structure md.js built for every sample in
// mac/Fixtures/markdown.json (recorded from it). New behaviour goes here and into new samples, written by hand.

import Foundation

public indirect enum MDInline: Equatable {
    case text(String)
    case code(String)
    case strong([MDInline])
    case em([MDInline])
    case del([MDInline])
    /// Only for http(s):// and mailto: addresses; any other [text](url) stays plain text. What is shown is
    /// `content` (the link text, the bare address, or the code span).
    case link(url: String, [MDInline])
}

public struct MDList: Equatable {
    public var ordered: Bool
    public var items: [MDItem]
}

public struct MDItem: Equatable {
    public var text: [MDInline]
    /// Lists nested under this item.
    public var lists: [MDList]
}

public indirect enum MDBlock: Equatable {
    /// `level` is the HTML level md.js uses: "#" is 3, "##" is 4, … at most 6 (headings inside an answer stay small).
    case heading(level: Int, [MDInline])
    /// Lines joined with line breaks.
    case paragraph([[MDInline]])
    /// `lang` is "" when the fence names none.
    case code(lang: String, text: String)
    case quote([MDBlock])
    case list(MDList)
    case table(header: [[MDInline]], rows: [[[MDInline]]])
    case rule
}

public enum Markdown {
    // the same expressions as md.js (\d and \w spelled out: JavaScript's are ASCII only)
    private static let inlineRE = re("(`[^`\\n]+`|\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|\\*[^*\\s][^*\\n]*\\*|~~[^~\\n]+~~|\\[[^\\]\\n]+\\]\\([^)\\s]+\\)|https?://[^\\s<>\"'`]+)")
    private static let bareURL = re("https?://[^\\s<>\"'`]+")
    private static let wholeURL = re("^https?://[^\\s<>\"'`]+$")
    private static let hostRE = re("^https?://[^/?#]")
    private static let linkRE = re("^\\[([^\\]]+)\\]\\(([^)\\s]+)\\)$")
    private static let safeURL = re("^(https?://|mailto:)", caseInsensitive: true)
    private static let listRE = re("^(\\s*)([-*+]|[0-9]+[.)])\\s+(.*)$")
    private static let tableSep = re("^\\s*\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?\\s*$")
    private static let blockStart = re("^(#{1,6}\\s|```|>\\s?|\\s*([-*_])\\2\\2+\\s*$)")
    private static let fenceOpen = re("^```\\s*([A-Za-z0-9_+#.-]*)\\s*$")
    private static let fenceClose = re("^```\\s*$")
    private static let blank = re("^\\s*$")
    private static let headingRE = re("^(#{1,6})\\s+(.*)$")
    private static let ruleRE = re("^\\s*([-*_])\\1\\1+\\s*$")
    private static let quoteRE = re("^>\\s?")
    private static let continuation = re("^\\s+\\S")

    private static func re(_ p: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let range = m.range(at: i)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static func test(_ r: NSRegularExpression, _ s: String) -> Bool { match(r, s) != nil }

    // MARK: addresses

    /// A bare address ends before trailing punctuation: "see http://x.com." or "(http://x.com)".
    public static func trimURL(_ url: String) -> String {
        var u = url
        while let c = u.last {
            if ".,;:!?'\"*_]}>".contains(c) { u.removeLast(); continue }
            if c == ")" && u.filter({ $0 == "(" }).count < u.filter({ $0 == ")" }).count { u.removeLast(); continue }
            break
        }
        return u
    }

    private static func hasHost(_ u: String) -> Bool { test(hostRE, u) }

    /// Plain text with its http(s) addresses as links (command output, the user's own message).
    public static func linkify(_ text: String) -> [MDInline] {
        let ns = text as NSString
        var out: [MDInline] = []
        var last = 0
        for m in bareURL.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let u = trimURL(ns.substring(with: m.range))
            guard hasHost(u) else { continue }
            if m.range.location > last { out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            out.append(.link(url: u, [.text(u)]))
            last = m.range.location + (u as NSString).length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    // MARK: inline

    /// Inline styles of one line of text.
    public static func inline(_ text: String) -> [MDInline] {
        let ns = text as NSString
        var out: [MDInline] = []
        var last = 0
        for m in inlineRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            let tok = ns.substring(with: m.range)
            let inner = { (cut: Int) -> String in
                let t = tok as NSString
                return t.substring(with: NSRange(location: cut, length: t.length - 2 * cut))
            }
            if tok.hasPrefix("`") {
                let u = inner(1)
                out.append(test(wholeURL, u) && trimURL(u) == u && hasHost(u) ? .link(url: u, [.code(u)]) : .code(u))
            }
            else if tok.hasPrefix("**") || tok.hasPrefix("__") { out.append(.strong(inline(inner(2)))) }
            else if tok.hasPrefix("~~") { out.append(.del(inline(inner(2)))) }
            else if tok.hasPrefix("*") { out.append(.em(inline(inner(1)))) }
            else if tok.hasPrefix("http") {
                let u = trimURL(tok)
                if hasHost(u) {
                    out.append(.link(url: u, [.text(u)]))
                    if u.count < tok.count { out.append(.text(String(tok.dropFirst(u.count)))) }
                } else { out.append(.text(tok)) }
            }
            else if let lm = match(linkRE, tok), test(safeURL, lm[2]) { out.append(.link(url: lm[2], [.text(lm[1])])) }
            else { out.append(.text(tok)) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    // MARK: blocks

    private static func splitRow(_ l: String) -> [String] {
        var s = l.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isBlockStart(_ l: String) -> Bool { test(blockStart, l) || test(listRE, l) }

    private final class ListNode { let ordered: Bool; var items: [ItemNode] = []; init(_ o: Bool) { ordered = o } }
    private final class ItemNode { let text: String; var lists: [ListNode] = []; init(_ t: String) { text = t } }

    /// md.js buildList(): items by indentation into nested lists.
    private static func buildLists(_ items: [(indent: Int, ordered: Bool, text: String)]) -> [MDList] {
        var roots: [ListNode] = []
        var stack: [(indent: Int, list: ListNode)] = []
        for it in items {
            while let top = stack.last, it.indent < top.indent { stack.removeLast() }
            if stack.isEmpty || it.indent > stack[stack.count - 1].indent {
                let list = ListNode(it.ordered)
                if let top = stack.last { top.list.items.last?.lists.append(list) } else { roots.append(list) }
                stack.append((it.indent, list))
            }
            stack[stack.count - 1].list.items.append(ItemNode(it.text))
        }
        func freeze(_ l: ListNode) -> MDList {
            MDList(ordered: l.ordered, items: l.items.map { MDItem(text: inline($0.text), lists: $0.lists.map(freeze)) })
        }
        return roots.map(freeze)
    }

    /// The blocks of a Markdown text (an answer may still be streaming in: an unclosed fence runs to the end).
    public static func parse(_ src: String) -> [MDBlock] {
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var i = 0
        func tableStarts(_ k: Int) -> Bool { lines[k].contains("|") && k + 1 < lines.count && test(tableSep, lines[k + 1]) }

        while i < lines.count {
            let line = lines[i]

            if let fence = match(fenceOpen, line) {
                var buf: [String] = []
                i += 1
                while i < lines.count && !test(fenceClose, lines[i]) { buf.append(lines[i]); i += 1 }
                i += 1                                   // the closing fence (may be missing while streaming)
                out.append(.code(lang: fence[1], text: buf.joined(separator: "\n")))
                continue
            }
            if test(blank, line) { i += 1; continue }

            if let hd = match(headingRE, line) {
                out.append(.heading(level: min(hd[1].count + 2, 6), inline(hd[2])))
                i += 1; continue
            }
            if test(ruleRE, line) { out.append(.rule); i += 1; continue }

            if test(quoteRE, line) {
                var buf: [String] = []
                while i < lines.count, let q = match(quoteRE, lines[i]) {
                    buf.append(String(lines[i].utf16.dropFirst(q[0].utf16.count)) ?? "")
                    i += 1
                }
                out.append(.quote(parse(buf.joined(separator: "\n"))))
                continue
            }

            if tableStarts(i) {
                let head = splitRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count && lines[i].contains("|") && !test(blank, lines[i]) { rows.append(splitRow(lines[i])); i += 1 }
                out.append(.table(header: head.map(inline), rows: rows.map { $0.map(inline) }))
                continue
            }

            if test(listRE, line) {
                var items: [(indent: Int, ordered: Bool, text: String)] = []
                while i < lines.count {
                    if let lm = match(listRE, lines[i]) {
                        items.append((lm[1].replacingOccurrences(of: "\t", with: "    ").utf16.count,
                                      lm[2].unicodeScalars.contains { ("0"..."9").contains($0) }, lm[3]))
                        i += 1
                    } else if test(continuation, lines[i]) && !items.isEmpty && !isBlockStart(lines[i]) {
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        i += 1
                    } else { break }
                }
                out += buildLists(items).map(MDBlock.list)
                continue
            }

            var buf: [String] = []
            while i < lines.count && !test(blank, lines[i]) && !isBlockStart(lines[i]) && !tableStarts(i) { buf.append(lines[i]); i += 1 }
            if buf.isEmpty { buf.append(lines[i]); i += 1 }
            out.append(.paragraph(buf.map(inline)))
        }
        return out
    }
}
