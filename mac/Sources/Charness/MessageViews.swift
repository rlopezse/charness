// The conversation: messages (Markdown answers, tool cards), the live activity while Claude works, and the
// approval cards. Ported from the retired web UI (app.js).

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import CharnessCore

// MARK: - small shared pieces

enum Palette {
    static let add = Color.green
    static let del = Color.red
    static let warn = Color.orange
    static var codeBackground: Color { Theme.code }
    static var cardBackground: Color { Theme.code }
    static var line: Color { Theme.border }
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
            Text(ClientText.fileSize(size)).foregroundStyle(Theme.secondaryText)
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

// MARK: - tool calls

/// What a tool is about to do (inputView() in app.js): a command, an edit as a diff, a file, a plan, or JSON.
struct ToolInputView: View {
    let name: String
    let input: JSONValue
    /// Claude Code's description of a command, under it. Off in a tool row, whose title already is that description.
    var showDescription = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch name {
            case "Bash":
                PreText(text: "$ " + input.text("command"))
                if showDescription, !input.text("description").isEmpty { Text(input.text("description")).font(.caption).foregroundStyle(Theme.secondaryText) }
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
        Text(input.text("file_path")).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
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

/// One tool call, as the Claude app shows it: a quiet line saying what Claude did ("List files in the project",
/// "Read Package.swift"). Closed by default; clicking it opens it like an accordion, showing the exact command or
/// input and what came back.
struct ToolCardView: View {
    let call: ToolCall
    let open: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: ToolIcon.name(call.name))
                        .font(.system(size: Theme.uiSize - 1))
                        .frame(width: 16)
                    Text(call.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(hover || open ? 1 : 0)
                    Spacer(minLength: 8)
                    StatusMark(status: call.status)
                }
                .font(Theme.font(Theme.uiSize))
                .foregroundStyle(hover || open ? Theme.text : Theme.secondaryText)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(call.summary)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ToolInputView(name: call.name, input: call.input, showDescription: false)
                    if let out = call.output, !out.isEmpty {
                        Text(call.status == "error" ? "Error" : "Output")
                            .font(Theme.font(Theme.uiSize - 1.5, weight: .medium))
                            .foregroundStyle(call.status == "error" ? Palette.del : Theme.secondaryText)
                        PreText(text: out.count > 4000 ? String(out.prefix(4000)) + "\n…" : out)
                    }
                }
                .padding(.leading, 23)   // lines up with the title, past the icon
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: open)
    }
}

/// How a tool call went, kept quiet: a spinner while it runs, nothing once it worked, a mark when it didn't.
struct StatusMark: View {
    let status: String
    var body: some View {
        switch status {
        case "running": ProgressView().controlSize(.mini)
        case "ok", "": EmptyView()
        default: StatusBadge(status: status)
        }
    }
}

// MARK: - messages

/// One message. Equatable so SwiftUI redraws only the messages that changed while an answer streams in.
/// What the reply being written shows in its header: what Claude is doing now, and since when it's been working.
struct LiveStatus: Equatable {
    let now: String?
    let since: Double
}

struct MessageRow: View, Equatable {
    let message: JSONValue
    let openTools: Set<String>
    let toggleTool: (String) -> Void
    /// Set on the reply Claude is still writing.
    var live: LiveStatus? = nil

    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.openTools == b.openTools && a.live == b.live
    }

    var body: some View {
        switch ChatMessage(message) {
        case .user(let text, let files):
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 6) {
                    if !text.isEmpty {
                        MarkdownView(text: text, user: true)   // Markdown, as in T3 Code
                    }
                    if !files.isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(Array(files.enumerated()), id: \.offset) { _, f in FileChip(name: f.name, size: f.size) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
            }
        case .compacted(let text):
            // a divider: what's above it now reaches Claude only as a summary
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(height: 1)
                Label("Conversation compacted", systemImage: "rectangle.compress.vertical")
                    .font(Theme.font(Theme.uiSize - 1))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .help(text)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .system(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        case .assistant(let blocks, let done):
            // as T3 Code shows a reply: its steps fold under "Working for 12s" while it runs, "Worked for 5.3s" after
            let layout = ReplyLayout(blocks)
            let workKey = "work:" + (Self.firstToolId(layout.work) ?? "")
            let workOpen = openTools.contains(workKey) && !layout.work.isEmpty
            VStack(alignment: .leading, spacing: 0) {
                if !layout.work.isEmpty || live != nil {
                    WorkHeader(title: ClientText.workedFor(done?.ms), live: live, canOpen: !layout.work.isEmpty, open: workOpen) {
                        toggleTool(workKey)
                    }
                    if workOpen {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 8)
                        StepsView(items: layout.work, openTools: openTools, toggleTool: toggleTool)
                            .padding(.top, 10)
                    }
                    if !layout.answer.isEmpty { Color.clear.frame(height: 12) }
                }
                StepsView(items: layout.answer, openTools: openTools, toggleTool: toggleTool)
                if let d = done {
                    // no dollar amount: on a subscription Claude Code's cost is only an API-price estimate (and it's
                    // the session's running total, not this reply's)
                    let line = ClientText.doneLine(cost: nil, turns: d.turns, ms: d.ms)
                    if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.tertiary).monospacedDigit().padding(.top, 8) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func firstToolId(_ items: [ReplyLayout.Item]) -> String? {
        for item in items {
            switch item {
            case .tool(let c): return c.id
            case .group(_, let calls): if let c = calls.first { return c.id }
            case .text: continue
            }
        }
        return nil
    }
}

// MARK: - the work log

/// "Worked for 5.3s ⌄", or while Claude works "Working for 12s ⌄  Running a command…": opens and closes the
/// reply's steps.
struct WorkHeader: View {
    let title: String
    var live: LiveStatus? = nil
    var canOpen = true
    let open: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if let live {
                    ProgressView().controlSize(.mini)
                    TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                        Text("Working for " + ClientText.elapsed(since: live.since, now: ctx.date.timeIntervalSince1970 * 1000))
                            .monospacedDigit()
                    }
                } else {
                    Text(title)
                }
                if canOpen {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                if let now = live?.now, !now.isEmpty {
                    Text(now)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 6)
                }
            }
            .font(Theme.font(Theme.uiSize))
            .foregroundStyle(hover && canOpen ? Theme.text : Theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canOpen)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: open)
    }
}

/// A reply's text and steps, top to bottom: steps one after another sit close together, text gets more room.
struct StepsView: View {
    let items: [ReplyLayout.Item]
    let openTools: Set<String>
    let toggleTool: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Group {
                    switch item {
                    case .text(let t):
                        MarkdownView(text: t)
                    case .tool(let call):
                        ToolCardView(call: call, open: openTools.contains(call.id)) { toggleTool(call.id) }
                    case .group(let title, let calls):
                        ToolGroupView(title: title, calls: calls, openTools: openTools, toggleTool: toggleTool)
                    }
                }
                .padding(.top, i == 0 ? 0 : (item.isStep && items[i - 1].isStep ? 8 : 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Steps in a row under one line: "Ran 2 commands, read a file", and the time they started on the right.
struct ToolGroupView: View {
    let title: String
    let calls: [ToolCall]
    let openTools: Set<String>
    let toggleTool: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: Self.icon(calls))
                    .font(.system(size: Theme.uiSize - 1))
                    .frame(width: 16)
                    .foregroundStyle(Theme.secondaryText)
                Text(title)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let at = calls.first?.at {
                    Text(Self.time(at))
                        .font(Theme.font(Theme.uiSize - 1.5))
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .font(Theme.font(Theme.uiSize))
            .padding(.bottom, 2)
            ForEach(calls, id: \.id) { call in
                ToolCardView(call: call, open: openTools.contains(call.id)) { toggleTool(call.id) }
            }
        }
    }

    /// The tools' own icon if they're all the same kind, a generic one otherwise.
    private static func icon(_ calls: [ToolCall]) -> String {
        let names = Set(calls.map { ToolIcon.name($0.name) })
        return names.count == 1 ? names.first! : "square.stack"
    }

    private static let today: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let otherDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Mdjmm")
        return f
    }()

    /// "12:23 AM" today, "11/21 12:23 AM" another day (in the Mac's own date format).
    static func time(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        return (Calendar.current.isDateInToday(d) ? today : otherDay).string(from: d)
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
                            .foregroundStyle(Theme.secondaryText)
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
            if let d = perm.description, !d.isEmpty { Text(d).foregroundStyle(Theme.secondaryText) }
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
                    VStack(alignment: .leading, spacing: 24) {
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .background(GeometryReader { g in
                        let f = g.frame(in: .named("conversation"))
                        Color.clear.preference(key: ContentMetricsKey.self, value: ContentMetrics(top: f.minY, bottom: f.maxY, height: f.height))
                    })
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                    .frame(maxWidth: Theme.columnWidth + 64)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
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
            let busy = s.busy.contains(cur.thread.id)
            let last = cur.messages.count - 1
            // while Claude writes its reply, the reply's own header says what it's doing (its steps folded under
            // it); the separate activity line only shows before the reply has started
            let replying = busy && last >= 0 && cur.messages[last].objectValue?["role"]?.stringValue == "assistant"
            ForEach(Array(cur.messages.enumerated()), id: \.offset) { i, m in
                MessageRow(message: m, openTools: model.openTools, toggleTool: { model.toggleTool($0) },
                           live: replying && i == last ? liveStatus(cur.messages, s.activity[cur.thread.id]) : nil)
                    .equatable()
            }
            if busy && !replying {
                ActivityView(activity: s.activity[cur.thread.id])
            }
            ForEach(s.currentPerms, id: \.id) { p in
                PermissionCard(perm: p) { model.answer(p, allow: $0) }
            }
        }
    }

    /// The reply's live header: what Claude is doing, and since the message that started this turn.
    private func liveStatus(_ messages: [JSONValue], _ activity: Activity?) -> LiveStatus {
        let asked = messages.last(where: { $0.objectValue?["role"]?.stringValue == "user" })?.objectValue?["ts"]?.doubleValue
        return LiveStatus(now: activity?.now, since: asked ?? activity?.since ?? Date().timeIntervalSince1970 * 1000)
    }
}
#endif
