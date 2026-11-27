// Markdown on screen: Claude's replies and your messages (both are Markdown, as in T3 Code), drawn after T3 Code's
// chat styles (apps/web/src/index.css, `.chat-markdown`), scaled to Theme.replySize: spacing between blocks,
// heading sizes, • ◦ ▪ and 1. a. i. list markers by depth, task-list checkboxes, tables with row lines only,
// quotes with a thin bar, inline code on a light tint, blue links. The parsing is CharnessCore/Markdown.swift
// (tested in core-checks); sizes and colors are in Theme.swift.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import CharnessCore

// MARK: - text runs

/// How a piece of text looks: size, weight, line spacing, code or not, and whose text it is.
struct RichStyle {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var lineSpacing: CGFloat = 2
    var mono = false
    /// Your message (the stronger text color) rather than Claude's reply (the softer one).
    var user = false

    static var body: RichStyle { RichStyle(size: Theme.replySize, lineSpacing: Theme.replyLineSpacing) }
    static var user: RichStyle { RichStyle(size: Theme.userSize, lineSpacing: Theme.userLineSpacing, user: true) }
    static var mono: RichStyle { RichStyle(size: Theme.monoSize, lineSpacing: 2, mono: true, user: true) }

    /// Paragraph text for a reply or for your message.
    static func text(user: Bool) -> RichStyle { user ? .user : .body }

    /// "#" is level 1.
    static func heading(_ level: Int, user: Bool) -> RichStyle {
        let sizes = Theme.headingSizes
        return RichStyle(size: sizes[min(max(level, 1), sizes.count) - 1], weight: .semibold, lineSpacing: 2, user: user)
    }

    static func table(user: Bool) -> RichStyle { RichStyle(size: Theme.tableSize, lineSpacing: 2, user: user) }

    var font: Font { mono ? .system(size: size, design: .monospaced) : Theme.font(size, weight: weight) }

    var nsFont: NSFont {
        mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : Theme.nsFont(size, weight: nsWeight)
    }

    var nsColor: NSColor { user ? Theme.nsText : Theme.nsReplyText }

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .semibold: return .semibold
        case .bold: return .bold
        case .medium: return .medium
        default: return .regular
        }
    }
}

enum MDText {
    /// Styled runs for SwiftUI's Text: bold / italic / strike-through as presentation intents, inline code in
    /// monospace on a light tint (85% of the text size), links as links.
    static func attributed(_ xs: [MDInline], _ intent: InlinePresentationIntent = [], size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for x in xs {
            switch x {
            case .text(let s):
                var a = AttributedString(s)
                if !intent.isEmpty { a.inlinePresentationIntent = intent }
                out.append(a)
            case .code(let s):
                var a = AttributedString(s)
                if !intent.isEmpty { a.inlinePresentationIntent = intent }
                a[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: (size * 0.85).rounded(), design: .monospaced)
                a[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Theme.inlineCode
                a[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.text
                out.append(a)
            case .strong(let k): out.append(attributed(k, intent.union(.stronglyEmphasized), size: size))
            case .em(let k): out.append(attributed(k, intent.union(.emphasized), size: size))
            case .del(let k): out.append(attributed(k, intent.union(.strikethrough), size: size))
            case .link(let url, let content):
                var a = attributed(content, intent, size: size)
                a.link = URL(string: url)
                out.append(a)
            }
        }
        return out
    }

    /// A paragraph's lines as one run of inlines, with line breaks between them.
    static func join(_ ls: [[MDInline]]) -> [MDInline] {
        var out: [MDInline] = []
        for (i, l) in ls.enumerated() {
            if i > 0 { out.append(.text("\n")) }
            out += l
        }
        return out
    }

    static func hasLink(_ xs: [MDInline]) -> Bool {
        xs.contains { x in
            switch x {
            case .link: return true
            case .strong(let k), .em(let k), .del(let k): return hasLink(k)
            case .text, .code: return false
            }
        }
    }

    /// The same runs for an NSTextView (fonts and attributes AppKit understands).
    static func ns(_ xs: [MDInline], font: NSFont, color: NSColor = Theme.nsText, bold: Bool = false, italic: Bool = false, code: Bool = false,
                   strike: Bool = false, link: URL? = nil, into out: NSMutableAttributedString = NSMutableAttributedString()) -> NSMutableAttributedString {
        for x in xs {
            switch x {
            case .text(let s), .code(let s):
                var isCode = code
                if case .code = x { isCode = true }
                var f = isCode ? NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.85).rounded(), weight: .regular) : font
                if bold {
                    let d = f.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold]])
                    f = NSFont(descriptor: d, size: f.pointSize) ?? f
                }
                if italic { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic)), size: f.pointSize) ?? f }
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: isCode ? Theme.nsText : color]
                if isCode { attrs[.backgroundColor] = Theme.nsInlineCode }
                if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link { attrs[.link] = link }
                out.append(NSAttributedString(string: s, attributes: attrs))
            case .strong(let k): _ = ns(k, font: font, color: color, bold: true, italic: italic, code: code, strike: strike, link: link, into: out)
            case .em(let k): _ = ns(k, font: font, color: color, bold: bold, italic: true, code: code, strike: strike, link: link, into: out)
            case .del(let k): _ = ns(k, font: font, color: color, bold: bold, italic: italic, code: code, strike: true, link: link, into: out)
            case .link(let url, let k): _ = ns(k, font: font, color: color, bold: bold, italic: italic, code: code, strike: strike, link: URL(string: url), into: out)
            }
        }
        return out
    }
}

/// Selectable text. With links in it, it is drawn by an NSTextView (LinkText), which keeps the plain arrow
/// over links and opens them in the default browser; SwiftUI's Text can't set the cursor for part of a text.
struct RichText: View {
    let inlines: [MDInline]
    var style: RichStyle = .body
    var strong = false

    var body: some View {
        if MDText.hasLink(inlines) {
            LinkText(string: MDText.ns(inlines, font: style.nsFont, color: style.nsColor, bold: strong), lineSpacing: style.lineSpacing)
        } else {
            Text(MDText.attributed(inlines, strong ? .stronglyEmphasized : [], size: style.size))
                .font(style.font)
                .fontWeight(strong ? .semibold : style.weight)
                .lineSpacing(style.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LinkText: NSViewRepresentable {
    let string: NSAttributedString
    var lineSpacing: CGFloat = 0

    /// The text with its line spacing (as SwiftUI's .lineSpacing gives the Text version).
    private var spaced: NSAttributedString {
        let m = NSMutableAttributedString(attributedString: string)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        return m
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        // links: blue and not underlined (as in T3 Code), and the plain arrow instead of AppKit's pointing hand
        // (a click still opens them in the default browser)
        tv.linkTextAttributes = [.foregroundColor: Theme.nsLink, .cursor: NSCursor.arrow]
        tv.textStorage?.setAttributedString(spaced)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        let s = spaced
        if tv.textStorage?.isEqual(to: s) != true { tv.textStorage?.setAttributedString(s) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let tc = tv.textContainer, let lm = tv.layoutManager else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        tc.containerSize = NSSize(width: proposed ?? 100_000, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let width = min(proposed ?? .greatestFiniteMagnitude, ceil(used.width))
        return CGSize(width: width, height: ceil(used.height))
    }
}

// MARK: - blocks

/// Markdown text: Claude's (replies, plans) in the reply color, or yours in your bubble.
struct MarkdownView: View {
    let text: String
    var user = false

    var body: some View {
        MDBlocksView(blocks: Markdown.parse(text), user: user)
            .foregroundStyle(user ? Theme.text : Theme.replyText)
    }
}

/// The blocks of a text. Paragraphs, headings, lists and quotes that follow one another are drawn as one piece of
/// text (FlowText), so a selection can run across them; code blocks, tables and rules are drawn on their own.
struct MDBlocksView: View {
    let blocks: [MDBlock]
    var user = false

    var body: some View {
        let segments = MDFlow.segments(blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                Group {
                    if seg.flow { FlowText(blocks: seg.blocks, user: user) }
                    else { MDBlockView(block: seg.blocks[0], user: user) }
                }
                .padding(.top, i == 0 ? 0 : MDFlow.gap(before: seg.blocks[0], after: segments[i - 1].blocks.last))
            }
        }
        // a reply fills the column; your message hugs its text, so the bubble does too
        .frame(maxWidth: user ? nil : .infinity, alignment: .leading)
    }
}

/// A block drawn on its own: a code block, a table or a rule.
struct MDBlockView: View {
    let block: MDBlock
    var user = false

    var body: some View {
        switch block {
        case .code(let lang, let text):
            CodeBlockView(lang: lang, code: text)
        case .table(let header, let rows):
            MDTableView(header: header, rows: rows, user: user)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        default:
            FlowText(blocks: [block], user: user)
        }
    }
}

// MARK: - flowing text

/// Paragraphs, headings, lists and quotes as one selectable text, drawn by an NSTextView: SwiftUI's Text only
/// selects within one Text, so a reply made of many couldn't be selected past a paragraph. Links are blue with the
/// plain arrow and open in the default browser.
struct FlowText: NSViewRepresentable {
    let blocks: [MDBlock]
    var user = false

    final class Coordinator {
        var blocks: [MDBlock]?
        var user = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: quotes are drawn with NSTextBlock, which TextKit 2 doesn't support
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(InlineCodeLayoutManager())
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.linkTextAttributes = [.foregroundColor: Theme.nsLink, .cursor: NSCursor.arrow]
        load(tv, context.coordinator)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) { load(tv, context.coordinator) }

    /// Sets the text only when it changed, so redraws don't clear what you selected.
    private func load(_ tv: NSTextView, _ c: Coordinator) {
        guard c.blocks != blocks || c.user != user else { return }
        c.blocks = blocks
        c.user = user
        tv.textStorage?.setAttributedString(MDFlow.build(blocks, user: user))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let tc = tv.textContainer, let lm = tv.layoutManager else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        tc.containerSize = NSSize(width: proposed ?? 100_000, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        // a reply takes the whole column; your message only as much as its text needs
        let width = user || proposed == nil ? min(proposed ?? .greatestFiniteMagnitude, textWidth(tv, lm, tc, wrapAt: proposed)) : proposed!
        return CGSize(width: width, height: ceil(used.height))
    }

    /// How wide the text really is: the widest laid-out line, and the text's own bounding box, whichever is less
    /// (the layout manager's used rect alone made your message bubbles as wide as the column).
    private func textWidth(_ tv: NSTextView, _ lm: NSLayoutManager, _ tc: NSTextContainer, wrapAt: CGFloat?) -> CGFloat {
        var widest: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, usedRect, _, _, _ in
            widest = max(widest, usedRect.maxX)
        }
        let box = tv.textStorage?.boundingRect(with: NSSize(width: wrapAt ?? 100_000, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).width ?? widest
        return ceil(min(widest, box > 0 ? box : widest))
    }
}

extension NSAttributedString.Key {
    /// Marks `inline code` in FlowText; InlineCodeLayoutManager draws its box.
    static let inlineCode = NSAttributedString.Key("CharnessInlineCode")
}

/// Draws the light rounded box behind `inline code`, as tall as the code's letters (not the whole line, as AppKit's
/// background color would be) and a little wider, one box per line when a span wraps.
final class InlineCodeLayoutManager: NSLayoutManager {
    /// The space kept after a span and before it (as kerning); half of it is the box's padding.
    static let room: CGFloat = 4

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        Theme.nsInlineCode.setFill()
        storage.enumerateAttribute(.inlineCode, in: chars) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                var box = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = lineRect.minY + self.location(forGlyphAt: part.location).y
                box.origin.y = baseline - font.ascender - 1.5
                box.size.height = font.ascender - font.descender + 3
                // the span's width includes the room kept after it: shift left by half of it
                let half = InlineCodeLayoutManager.room / 2
                box.origin.x -= half
                box.size.width -= half
                if box.minX < 0 { box.size.width += box.minX; box.origin.x = 0 }   // code at the start of a line: no room to its left
                box = box.offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// Builds FlowText's text: the same sizes, colors and spacing as T3 Code's chat (Theme), as paragraph styles.
enum MDFlow {
    struct Segment {
        var flow: Bool
        var blocks: [MDBlock]
    }

    static func isFlow(_ b: MDBlock) -> Bool {
        switch b {
        case .code, .table, .rule: return false
        default: return true
        }
    }

    /// Runs of flowing blocks together; every other block on its own.
    static func segments(_ blocks: [MDBlock]) -> [Segment] {
        var out: [Segment] = []
        for b in blocks {
            if isFlow(b), out.last?.flow == true { out[out.count - 1].blocks.append(b) }
            else { out.append(Segment(flow: isFlow(b), blocks: [b])) }
        }
        return out
    }

    /// T3 Code's margins: more room above a heading, less below it, the same between everything else.
    static func gap(before b: MDBlock, after prev: MDBlock?) -> CGFloat {
        guard let prev else { return 0 }
        if case .heading = b { return Theme.headingGapAbove }
        if case .heading = prev { return Theme.headingGapBelow }
        return Theme.blockGap
    }

    static func build(_ blocks: [MDBlock], user: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        add(blocks, user: user, quotes: [], leading: 0, into: out)
        // Inline code: AppKit's own background would fill the whole line height (line spacing included), so the
        // boxes are drawn by InlineCodeLayoutManager instead, around the text only; a little space after the span
        // and before it leaves room for their padding.
        var spans: [NSRange] = []
        out.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: out.length)) { v, r, _ in
            if v != nil { spans.append(r) }
        }
        let text = out.string as NSString
        for var r in spans {
            out.removeAttribute(.backgroundColor, range: r)
            // never a box over a line break
            while r.length > 0 && text.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
            guard r.length > 0 else { continue }
            out.addAttribute(.inlineCode, value: true, range: r)
            out.addAttribute(.kern, value: InlineCodeLayoutManager.room, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
            if r.location > 0, (out.string as NSString).character(at: r.location - 1) != 10 {
                out.addAttribute(.kern, value: InlineCodeLayoutManager.room, range: NSRange(location: r.location - 1, length: 1))
            }
        }
        return out
    }

    /// How one block's paragraphs are laid out: room above the block, line spacing, indents (a list item's text
    /// sits at `head`, its marker at `indent`), and the quote bars around it.
    private struct Para {
        var gap: CGFloat
        var lineSpacing: CGFloat
        var indent: CGFloat = 0
        var head: CGFloat = 0
        var quotes: [NSTextBlock]

        func style(first: Bool) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineSpacing
            p.paragraphSpacingBefore = first ? gap : 0
            p.firstLineHeadIndent = first ? indent : head
            p.headIndent = head
            if head > indent {
                p.tabStops = [NSTextTab(textAlignment: .left, location: head)]
                p.defaultTabInterval = head - indent
            }
            p.textBlocks = quotes
            return p
        }
    }

    /// Adds one block's text as paragraphs: the room above goes on its first line only.
    private static func emit(_ s: NSMutableAttributedString, _ para: Para, into out: NSMutableAttributedString) {
        if out.length > 0 {
            // the line break ending the previous block keeps only its font and paragraph style: carrying an inline
            // code background (or a link) onto it would stretch that box to the end of the line
            let prev = out.attributes(at: out.length - 1, effectiveRange: nil).filter { $0.key == .font || $0.key == .paragraphStyle }
            out.append(NSAttributedString(string: "\n", attributes: prev))
        }
        let firstBreak = (s.string as NSString).range(of: "\n").location
        s.addAttribute(.paragraphStyle, value: para.style(first: false), range: NSRange(location: 0, length: s.length))
        let firstLength = firstBreak == NSNotFound ? s.length : firstBreak + 1
        s.addAttribute(.paragraphStyle, value: para.style(first: true), range: NSRange(location: 0, length: firstLength))
        out.append(s)
    }

    private static func add(_ blocks: [MDBlock], user: Bool, quotes: [NSTextBlock], leading: CGFloat, into out: NSMutableAttributedString) {
        let body = RichStyle.text(user: user)
        for (i, b) in blocks.enumerated() {
            let space = i == 0 ? leading : gap(before: b, after: blocks[i - 1])
            switch b {
            case .heading(let level, let text):
                // Markdown.swift numbers "#" as 3, "##" as 4, … (the levels md.js used)
                let st = RichStyle.heading(level - 2, user: user)
                emit(MDText.ns(text, font: st.nsFont, color: Theme.nsText), Para(gap: space, lineSpacing: 2, quotes: quotes), into: out)
            case .paragraph(let lines):
                emit(MDText.ns(MDText.join(lines), font: body.nsFont, color: body.nsColor),
                     Para(gap: space, lineSpacing: body.lineSpacing, quotes: quotes), into: out)
            case .quote(let inner):
                // a thin bar on the left, the text 11 points in
                let q = NSTextBlock()
                q.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
                q.setBorderColor(NSColor.labelColor.withAlphaComponent(0.35), for: .minX)
                q.setWidth(11, type: .absoluteValueType, for: .padding, edge: .minX)
                add(inner, user: user, quotes: quotes + [q], leading: space, into: out)
            case .list(let l):
                list(l, depth: 0, user: user, quotes: quotes, leading: space, into: out)
            case .code(_, let text):   // only inside a quote; elsewhere code blocks are drawn on their own
                let s = NSMutableAttributedString(string: text, attributes: [.font: RichStyle.mono.nsFont, .foregroundColor: Theme.nsText])
                emit(s, Para(gap: space, lineSpacing: 3, quotes: quotes), into: out)
            case .table(let header, let rows):   // the same: a table inside a quote, as lines of cells
                let st = RichStyle.table(user: user)
                let s = NSMutableAttributedString()
                for (r, cells) in ([header] + rows).enumerated() {
                    if r > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: st.nsFont])) }
                    for (c, cell) in cells.enumerated() {
                        if c > 0 { s.append(NSAttributedString(string: "  ·  ", attributes: [.font: st.nsFont, .foregroundColor: Theme.nsSecondaryText])) }
                        _ = MDText.ns(cell, font: st.nsFont, color: st.nsColor, bold: r == 0, into: s)
                    }
                }
                emit(s, Para(gap: space, lineSpacing: 2, quotes: quotes), into: out)
            case .rule:
                let s = NSMutableAttributedString(string: "———", attributes: [.font: body.nsFont, .foregroundColor: Theme.nsSecondaryText])
                emit(s, Para(gap: space, lineSpacing: 2, quotes: quotes), into: out)
            }
        }
    }

    /// A list: • ◦ ▪ or 1. a. i. by depth (your messages keep 1. 2. 3.), ☐ ☑ for tasks; the marker in a gutter,
    /// the text (and its wrapped lines) lined up after it.
    private static func list(_ l: MDList, depth: Int, user: Bool, quotes: [NSTextBlock], leading: CGFloat, into out: NSMutableAttributedString) {
        let body = RichStyle.text(user: user)
        let gutter = Theme.listGutter + 4
        let indent = CGFloat(depth) * gutter
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: body.size, weight: .regular)
        for (i, item) in l.items.enumerated() {
            let marker: String
            if let done = item.task { marker = done ? "☑" : "☐" }
            else if l.ordered { marker = number(l.start + i, depth: user ? 0 : depth) }
            else { marker = ["•", "◦", "▪"][min(depth, 2)] }
            let s = NSMutableAttributedString(string: marker + "\t", attributes: [.font: markerFont, .foregroundColor: Theme.nsSecondaryText])
            _ = MDText.ns(item.text, font: body.nsFont, color: body.nsColor, into: s)
            emit(s, Para(gap: i == 0 ? leading : Theme.listItemGap, lineSpacing: body.lineSpacing, indent: indent, head: indent + gutter, quotes: quotes),
                 into: out)
            for sub in item.lists {
                list(sub, depth: depth + 1, user: user, quotes: quotes, leading: Theme.listItemGap, into: out)
            }
        }
    }

    /// 1. 2. 3. at the top, a. b. c. one level in, i. ii. iii. below that.
    static func number(_ n: Int, depth: Int) -> String {
        switch depth {
        case 0: return "\(n)."
        case 1: return "\(alpha(n))."
        default: return "\(roman(n))."
        }
    }

    private static func alpha(_ n: Int) -> String {
        var n = max(n, 1), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n /= 26 }
        return s
    }

    private static func roman(_ n: Int) -> String {
        guard n > 0 && n < 4000 else { return "\(n)" }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }
}

// MARK: - tables

/// T3 Code's tables: as wide as the column, lines between rows only, the outer columns flush with the text,
/// a semibold header, text one step smaller, long cells wrapping; a table too wide for the column scrolls.
struct MDTableView: View {
    let header: [[MDInline]]
    let rows: [[[MDInline]]]
    var user = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal) { grid.padding(.bottom, 6) }
        }
    }

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cells(header, header: true) }
            line
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow { cells(r, header: false) }
                line
            }
        }
    }

    private var line: some View {
        Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
    }

    @ViewBuilder private func cells(_ r: [[MDInline]], header: Bool) -> some View {
        ForEach(0..<columns, id: \.self) { c in
            RichText(inlines: c < r.count ? r[c] : [], style: .table(user: user), strong: header)
                .frame(maxWidth: Theme.tableCellMaxWidth, alignment: .leading)
                .padding(.leading, c == 0 ? 0 : 12)
                .padding(.trailing, c == columns - 1 ? 0 : 12)
                .padding(.vertical, header ? 9 : 7)
        }
    }
}

// MARK: - code blocks

struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "text" : lang)
                    .font(Theme.font(Theme.monoSize - 1))
                    .foregroundStyle(Theme.text.opacity(0.72))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(.borderless)
                .font(Theme.font(Theme.monoSize - 1))
                .foregroundStyle(Theme.text.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal) {
                Text(Self.colored(code, lang))
                    .font(.system(size: Theme.monoSize, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 11)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.code))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border))
    }

    /// The code in T3 Code's colors, for the languages Syntax knows (JavaScript, TypeScript, JSON, HTML, CSS);
    /// anything else in the plain text color.
    static func colored(_ code: String, _ lang: String) -> AttributedString {
        guard !code.isEmpty else { return AttributedString(" ") }
        var out = AttributedString()
        for t in Syntax.highlight(code, language: lang) {
            var run = AttributedString(t.text)
            if let c = Theme.syntax[t.kind] { run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = c }
            out.append(run)
        }
        return out
    }
}
#endif
