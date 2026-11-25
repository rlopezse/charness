// The conversation: messages (Markdown answers, tool cards), the live activity while Claude works, and the
// approval cards. Same content and rules as public/app.js's msgNode/toolCard/inputView/renderActivity/permCard.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import CharnessCore

// MARK: - small shared pieces

enum Palette {
    static let add = Color.green
    static let del = Color.red
    static let warn = Color.orange
    static var codeBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var line: Color { Color.secondary.opacity(0.25) }
}

/// Preformatted text (commands, file contents, output), selectable; web addresses in it are links.
struct PreText: View {
    let text: String
    var body: some View {
        RichText(inlines: text.isEmpty ? [.text(" ")] : Markdown.linkify(text), style: .mono)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
    }
}

enum DiffKind { case add, del, plain }

/// Lines of a diff, colored; lazy so a long diff stays quick.
struct DiffLinesView: View {
    let lines: [(String, DiffKind)]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.0.isEmpty ? " " : l.0)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(l.1 == .add ? Palette.add : l.1 == .del ? Palette.del : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(l.1 == .add ? Palette.add.opacity(0.08) : l.1 == .del ? Palette.del.opacity(0.08) : Color.clear)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
    }

    /// An edit as "- old" / "+ new" lines (diffBlock() in app.js).
    static func edit(_ old: String, _ new: String) -> [(String, DiffKind)] {
        old.components(separatedBy: "\n").map { ("- \($0)", .del) } + new.components(separatedBy: "\n").map { ("+ \($0)", .add) }
    }

    /// `git diff` output, colored like the Changes panel.
    static func git(_ diff: String) -> [(String, DiffKind)] {
        diff.components(separatedBy: "\n").map { l in
            (l, l.hasPrefix("+") && !l.hasPrefix("+++") ? .add : l.hasPrefix("-") && !l.hasPrefix("---") ? .del : .plain)
        }
    }
}

struct FileChip: View {
    let name: String
    let size: Int
    var onRemove: (() -> Void)?
    var body: some View {
        HStack(spacing: 4) {
            Text(ClientText.fileIcon(name))
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
            Text(ClientText.fileSize(size)).foregroundColor(.secondary)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove \(name)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.cardBackground))
        .overlay(Capsule().stroke(Palette.line))
        .help(name)
    }
}

// MARK: - Markdown

enum MDText {
    /// Styled runs for SwiftUI's Text: bold / italic / code / strike-through as presentation intents, links as links.
    static func attributed(_ xs: [MDInline], _ intent: InlinePresentationIntent = []) -> AttributedString {
        var out = AttributedString()
        for x in xs {
            switch x {
            case .text(let s):
                var a = AttributedString(s)
                if !intent.isEmpty { a.inlinePresentationIntent = intent }
                out.append(a)
            case .code(let s):
                var a = AttributedString(s)
                a.inlinePresentationIntent = intent.union(.code)
                out.append(a)
            case .strong(let k): out.append(attributed(k, intent.union(.stronglyEmphasized)))
            case .em(let k): out.append(attributed(k, intent.union(.emphasized)))
            case .del(let k): out.append(attributed(k, intent.union(.strikethrough)))
            case .link(let url, let content):
                var a = attributed(content, intent)
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
    static func ns(_ xs: [MDInline], font: NSFont, bold: Bool = false, italic: Bool = false, code: Bool = false,
                   strike: Bool = false, link: URL? = nil, into out: NSMutableAttributedString = NSMutableAttributedString()) -> NSMutableAttributedString {
        for x in xs {
            switch x {
            case .text(let s), .code(let s):
                var isCode = code
                if case .code = x { isCode = true }
                var f = isCode ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
                if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor]
                if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link { attrs[.link] = link }
                out.append(NSAttributedString(string: s, attributes: attrs))
            case .strong(let k): _ = ns(k, font: font, bold: true, italic: italic, code: code, strike: strike, link: link, into: out)
            case .em(let k): _ = ns(k, font: font, bold: bold, italic: true, code: code, strike: strike, link: link, into: out)
            case .del(let k): _ = ns(k, font: font, bold: bold, italic: italic, code: code, strike: true, link: link, into: out)
            case .link(let url, let k): _ = ns(k, font: font, bold: bold, italic: italic, code: code, strike: strike, link: URL(string: url), into: out)
            }
        }
        return out
    }
}

enum RichStyle {
    case body, title, headline, subheadline, mono

    var font: Font {
        switch self {
        case .body: return .body
        case .title: return .title3.bold()
        case .headline: return .headline
        case .subheadline: return .subheadline.bold()
        case .mono: return .system(.callout, design: .monospaced)
        }
    }

    var nsFont: NSFont {
        switch self {
        case .body: return .systemFont(ofSize: NSFont.systemFontSize)
        case .title: return .boldSystemFont(ofSize: 15)
        case .headline: return .boldSystemFont(ofSize: NSFont.systemFontSize)
        case .subheadline: return .boldSystemFont(ofSize: 11)
        case .mono: return .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
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
            LinkText(string: MDText.ns(inlines, font: style.nsFont, bold: strong))
        } else {
            Text(MDText.attributed(inlines, strong ? .stronglyEmphasized : []))
                .font(style.font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LinkText: NSViewRepresentable {
    let string: NSAttributedString

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
        // links: link color, and the plain arrow instead of AppKit's pointing hand (a click still opens them)
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.arrow]
        tv.textStorage?.setAttributedString(string)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.textStorage?.isEqual(to: string) != true { tv.textStorage?.setAttributedString(string) }
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

struct MarkdownView: View {
    let text: String
    var body: some View { MDBlocksView(blocks: Markdown.parse(text)) }
}

struct MDBlocksView: View {
    let blocks: [MDBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in MDBlockView(block: b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MDBlockView: View {
    let block: MDBlock
    var body: some View {
        switch block {
        case .heading(let level, let text):
            RichText(inlines: text, style: level <= 3 ? .title : level == 4 ? .headline : .subheadline)
                .padding(.top, 4)
        case .paragraph(let lines):
            RichText(inlines: MDText.join(lines))
        case .code(let lang, let text):
            CodeBlockView(lang: lang, code: text)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                MDBlocksView(blocks: inner).foregroundColor(.secondary)
            }
        case .list(let list):
            MDListView(list: list)
        case .table(let header, let rows):
            MDTableView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

struct MDListView: View {
    let list: MDList
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(list.ordered ? "\(i + 1)." : "•").foregroundColor(.secondary).frame(minWidth: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        RichText(inlines: item.text)
                        ForEach(Array(item.lists.enumerated()), id: \.offset) { _, sub in MDListView(list: sub) }
                    }
                }
            }
        }
    }
}

struct MDTableView: View {
    let header: [[MDInline]]
    let rows: [[[MDInline]]]
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, bold: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    row(r, bold: false)
                    Divider().opacity(0.5)
                }
            }
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
    }

    private func row(_ cells: [[MDInline]], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                RichText(inlines: c, strong: bold)
                    .frame(minWidth: 60, maxWidth: 260, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "text" : lang).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
    }
}

// MARK: - tool calls

/// What a tool is about to do (inputView() in app.js): a command, an edit as a diff, a file, a plan, or JSON.
struct ToolInputView: View {
    let name: String
    let input: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch name {
            case "Bash":
                PreText(text: "$ " + input.text("command"))
                if !input.text("description").isEmpty { Text(input.text("description")).font(.caption).foregroundColor(.secondary) }
            case "Edit":
                pathLabel
                DiffLinesView(lines: DiffLinesView.edit(input.text("old_string"), input.text("new_string")))
            case "MultiEdit":
                pathLabel
                ForEach(Array((input.objectValue?["edits"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, e in
                    DiffLinesView(lines: DiffLinesView.edit(e.text("old_string"), e.text("new_string")))
                }
            case "Write":
                pathLabel
                PreText(text: ClientText.firstLines(input.text("content"), 60))
            case "ExitPlanMode":
                MarkdownView(text: input.text("plan"))
            default:
                PreText(text: input.jsonString(pretty: true))
            }
        }
    }

    private var pathLabel: some View {
        Text(input.text("file_path")).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        Group {
            switch status {
            case "running": ProgressView().controlSize(.mini)
            case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.add)
            case "error": Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.del)
            case "denied": Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warn)
            default: Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(status)
    }
}

enum ToolIcon {
    static func name(_ tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text"
        case "Glob", "Grep", "LS": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "ExitPlanMode": return "list.bullet.clipboard"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct ToolCardView: View {
    let call: ToolCall
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: ToolIcon.name(call.name)).foregroundStyle(.secondary).frame(width: 16)
                    Text(call.name).fontWeight(.medium)
                    Text(call.summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    StatusBadge(status: call.status)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ToolInputView(name: call.name, input: call.input)
                    if let out = call.output, !out.isEmpty {
                        Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        PreText(text: out.count > 4000 ? String(out.prefix(4000)) + "\n…" : out)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(call.status == "error" ? Palette.del.opacity(0.4) : Color.primary.opacity(0.07)))
    }
}

// MARK: - messages

/// One message. Equatable so SwiftUI redraws only the messages that changed while an answer streams in.
struct MessageRow: View, Equatable {
    let message: JSONValue
    let openTools: Set<String>
    let toggleTool: (String) -> Void

    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.openTools == b.openTools
    }

    var body: some View {
        switch ChatMessage(message) {
        case .user(let text, let files):
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !text.isEmpty {
                        RichText(inlines: Markdown.linkify(text))
                    }
                    if !files.isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(Array(files.enumerated()), id: \.offset) { _, f in FileChip(name: f.name, size: f.size) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.16)))
            }
        case .system(let text):
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        case .assistant(let blocks, let done):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    switch b {
                    case .text(let t): MarkdownView(text: t)
                    case .tool(let call): ToolCardView(call: call, open: openTools.contains(call.id)) { toggleTool(call.id) }
                    }
                }
                if let d = done {
                    let line = ClientText.doneLine(cost: d.cost, turns: d.turns, ms: d.ms)
                    if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - live activity and approvals

struct ActivityView: View {
    let activity: Activity?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activity == nil ? "Working…" : (activity?.now ?? "Finishing…"))
                Spacer()
                if let since = activity?.since, since > 0 {
                    TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                        Text(ClientText.elapsed(since: since, now: ctx.date.timeIntervalSince1970 * 1000))
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            ForEach(Array((activity?.steps ?? []).enumerated()), id: \.offset) { _, st in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(st.status == "ok" ? "✓" : st.status == "error" ? "✗" : "•")
                        .foregroundColor(st.status == "ok" ? Palette.add : st.status == "error" ? Palette.del : .secondary)
                    Text(st.text).lineLimit(1).truncationMode(.middle).foregroundColor(st.status == "running" ? .primary : .secondary)
                }
                .font(.callout)
                .padding(.leading, st.sub ? 18 : 0)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PermissionCard: View {
    let perm: PendingPermission
    let answer: (Bool) -> Void

    var body: some View {
        let plan = perm.tool == "ExitPlanMode"
        VStack(alignment: .leading, spacing: 10) {
            Text(plan ? "Claude has a plan — approve it?" : (perm.title ?? "Claude wants to use \(perm.tool)"))
                .font(.headline)
            if let d = perm.description, !d.isEmpty { Text(d).foregroundColor(.secondary) }
            ToolInputView(name: perm.tool, input: perm.input)
            HStack(spacing: 10) {
                if perm.defaultToNo {
                    Button(plan ? "Approve plan" : "Allow") { answer(true) }.buttonStyle(.bordered)
                    Button(plan ? "Keep planning" : "Deny") { answer(false) }.buttonStyle(.borderedProminent)
                } else {
                    Button(plan ? "Approve plan" : "Allow") { answer(true) }.buttonStyle(.borderedProminent)
                    Button(plan ? "Keep planning" : "Deny") { answer(false) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.warn.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.warn.opacity(0.6)))
    }
}

// MARK: - the scrolling conversation

/// Where the conversation's content ends (in the scroll view's visible area) and how tall it is.
private struct ContentMetrics: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var height: CGFloat = 0
}

private struct ContentMetricsKey: PreferenceKey {
    static var defaultValue = ContentMetrics()
    static func reduce(value: inout ContentMetrics, nextValue: () -> ContentMetrics) { value = nextValue() }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel
    /// Follow new content only while the view is (nearly) at the bottom, like app.js's `stick`. Only scrolling
    /// by the user changes it: content growing at the bottom must not count as "scrolled away".
    @State private var stick = true
    @State private var lastHeight: CGFloat = 0
    @State private var lastTop: CGFloat = 0

    var body: some View {
        let s = model.s
        if !model.ready || model.loadingThread {
            ProgressView().controlSize(.regular)
        } else if let cur = s.current, !(cur.messages.isEmpty && !s.busy.contains(cur.thread.id) && s.currentPerms.isEmpty) {
            conversation
        } else if let cur = s.current {
            ContentUnavailableView {
                Label(cur.thread.title, systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Ask Claude anything about this project.")
            }
        } else if s.projects.isEmpty {
            ContentUnavailableView {
                Label("Welcome to Charness", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a project folder to begin. Claude works inside that folder only.")
            } actions: {
                Button("Add Project…") { model.chooseProjectFolder() }
            }
        } else {
            ContentUnavailableView {
                Label("No Thread Open", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a thread in the sidebar, or start a new one.")
            } actions: {
                Button("New Thread") { model.newThreadHere() }
            }
        }
    }

    private var conversation: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .background(GeometryReader { g in
                        let f = g.frame(in: .named("conversation"))
                        Color.clear.preference(key: ContentMetricsKey.self, value: ContentMetrics(top: f.minY, bottom: f.maxY, height: f.height))
                    })
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "conversation")
                .onPreferenceChange(ContentMetricsKey.self) { m in
                    let fromBottom = m.bottom - outer.size.height
                    let grew = abs(m.height - lastHeight) > 0.5
                    // The content's top moving down while it didn't shrink means the user scrolled up: stop
                    // following. (Growth at the bottom leaves the top where it is; a shrink can move it.)
                    if m.top > lastTop + 2 && m.height >= lastHeight - 0.5 { stick = false }
                    if fromBottom < 80 { stick = true }          // back at the bottom: follow again
                    lastTop = m.top
                    lastHeight = m.height
                    // new content while following (an answer streaming in, a tool card, the activity): keep up
                    if grew && stick { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: model.scrollRequest) { _, _ in
                    stick = true
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    // and again once whatever caused it (a sent message, an approval card) has been laid out
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let s = model.s
        if let cur = s.current {
            ForEach(Array(cur.messages.enumerated()), id: \.offset) { _, m in
                MessageRow(message: m, openTools: model.openTools, toggleTool: { model.toggleTool($0) }).equatable()
            }
            if s.busy.contains(cur.thread.id) {
                ActivityView(activity: s.activity[cur.thread.id])
            }
            ForEach(s.currentPerms, id: \.id) { p in
                PermissionCard(perm: p) { model.answer(p, allow: $0) }
            }
        }
    }
}
#endif
