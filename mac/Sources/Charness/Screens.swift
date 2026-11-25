// The native window, built from the standard Mac pieces (macOS 14): a split view with the projects and threads
// in a sidebar list, the conversation with its message box as the detail, the thread's model / mode and the
// Changes / Network panels in the title-bar toolbar and an inspector. Same features as public/app.js.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CharnessCore

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            DetailView(model: model)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 96)
                    .onTapGesture { model.dismissToast() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

// MARK: - sidebar

private enum DeleteTarget {
    case project(id: String, name: String)
    case thread(id: String, title: String)
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var confirm: DeleteTarget?
    @State private var renaming: ChatThread?
    @State private var newTitle = ""

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { id in
            if let id, id != model.s.current?.thread.id { model.openThread(id) }
        })) {
            if model.ready && model.s.projects.isEmpty {
                Text("No projects yet").foregroundStyle(.secondary)
            }
            ForEach(model.s.projects, id: \.id) { p in
                Section(isExpanded: Binding(get: { !model.collapsed.contains(p.id) }, set: { open in
                    if open { model.collapsed.remove(p.id) } else { model.collapsed.insert(p.id) }
                })) {
                    let threads = model.s.threads(of: p.id)
                    if threads.isEmpty {
                        Text("No threads yet").foregroundStyle(.tertiary)
                    }
                    ForEach(threads, id: \.id) { t in
                        ThreadRow(model: model, thread: t)
                            .tag(t.id)
                            .contextMenu {
                                Button("Rename…") { newTitle = t.title; renaming = t }
                                Divider()
                                Button("Delete Thread…", role: .destructive) { confirm = .thread(id: t.id, title: t.title) }
                            }
                    }
                } header: {
                    ProjectHeader(project: p) { model.newThread(p.id) }
                        .contextMenu {
                            Button("New Thread") { model.newThread(p.id) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
                            }
                            Divider()
                            Button("Remove Project…", role: .destructive) { confirm = .project(id: p.id, name: p.name) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for f in folders { model.addProject(f.path) }
            return !folders.isEmpty
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button(confirmButton, role: .destructive) {
                switch confirm {
                case .project(let id, _): model.deleteProject(id)
                case .thread(let id, _): model.deleteThread(id)
                case nil: break
                }
                confirm = nil
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text(confirmMessage)
        }
        .alert("Rename Thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let t = renaming { model.renameThread(t.id, newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .project(_, let name): return "Remove the project “\(name)”?"
        case .thread(_, let title): return "Delete the thread “\(title)”?"
        case nil: return ""
        }
    }
    private var confirmButton: String {
        if case .project = confirm { return "Remove Project" }
        return "Delete Thread"
    }
    private var confirmMessage: String {
        if case .project = confirm { return "Its threads are deleted from Charness. The folder on disk is not touched." }
        return "Its messages are deleted from Charness. Files Claude changed stay as they are."
    }

    private var footer: some View {
        let s = model.s
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { model.chooseProjectFolder() } label: {
                    Label("Add Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Choose a folder for Claude to work in (or drop one on the sidebar)")
                Spacer()
                Button { model.toggleDrawer(.network) } label: {
                    Image(systemName: !s.guardOn ? "shield.slash" : s.blockedCount > 0 ? "exclamationmark.shield" : "checkmark.shield")
                        .foregroundStyle(!s.guardOn ? Color.secondary : s.blockedCount > 0 ? Color.orange : Color.green)
                }
                .buttonStyle(.borderless)
                .help(s.guardOn ? "Egress guard on · \(s.allow.count) allowed · \(s.blockedCount) blocked" : "Egress guard OFF")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}

struct ProjectHeader: View {
    let project: Project
    let onNewThread: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .help(project.path)
            Spacer(minLength: 4)
            Button(action: onNewThread) { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New thread")
                .opacity(hovering ? 1 : 0.55)
        }
        .onHover { hovering = $0 }
    }
}

struct ThreadRow: View {
    @ObservedObject var model: AppModel
    let thread: ChatThread

    var body: some View {
        let needs = model.s.needsApproval(thread.id)
        let busy = model.s.busy.contains(thread.id)
        HStack(spacing: 6) {
            Text(thread.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if needs {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Waiting for your approval")
            } else if busy {
                ProgressView().controlSize(.mini).help("Running")
            }
        }
    }
}

// MARK: - detail: conversation, message box, toolbar, inspector

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let t = model.s.current?.thread
        VStack(spacing: 0) {
            if model.everConnected && !model.s.connected {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting to the Charness server…")
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(Color.orange.opacity(0.15))
            }
            ConversationView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if t != nil || model.loadingThread {
                ComposerView(model: model)
            }
        }
        .navigationTitle(t?.title ?? "Charness")
        .navigationSubtitle(subtitle)
        .toolbar {
            // the thread's model and mode are next to the message box (ComposerView)
            ToolbarItem(placement: .primaryAction) {
                Button { model.toggleDrawer(.changes) } label: { Label("Changes", systemImage: "plusminus") }
                    .help("Changes in the project (git)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.toggleDrawer(.network) } label: { Label("Network", systemImage: "network") }
                    .help("Network log and allow-list")
            }
        }
        .inspector(isPresented: Binding(get: { model.drawer != nil }, set: { show in
            if !show { model.drawer = nil } else if model.drawer == nil { model.toggleDrawer(.changes) }
        })) {
            DrawerView(model: model)
                .inspectorColumnWidth(min: 300, ideal: 400, max: 700)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard t != nil, !model.isBusy else { return false }
            let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            if files.isEmpty { return false }
            model.attach(files)
            return true
        }
    }

    private var subtitle: String {
        var bits: [String] = []
        if let t = model.s.current?.thread, let p = model.s.projects.first(where: { $0.id == t.projectId }) { bits.append(p.name) }
        if model.s.mock { bits.append("MOCK") }
        return bits.joined(separator: " · ")
    }
}

struct ComposerView: View {
    @ObservedObject var model: AppModel
    @State private var height: CGFloat = 34

    var body: some View {
        let t = model.s.current?.thread
        let busy = model.isBusy
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { a in
                            FileChip(name: a.name, size: a.size) { model.removeAttachment(a) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                Button { model.pickFiles() } label: {
                    Image(systemName: "paperclip").font(.system(size: 15)).frame(width: 28, height: 30)
                }
                .buttonStyle(.borderless)
                .help("Attach files (or drop them here)")
                .disabled(t == nil || busy || model.uploading != nil)

                ZStack(alignment: .topLeading) {
                    ComposerTextView(text: $model.draft, height: $height, enabled: t != nil,
                                     focusRequest: model.focusRequest, onSend: { model.sendOrStop() })
                    if model.draft.isEmpty {
                        Text(t == nil ? "Loading…" : "Message Claude")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 9)
                            .padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: height)

                if busy {
                    Button { model.sendOrStop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                    .frame(width: 30, height: 30)
                } else if model.uploading != nil {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    Button { model.sendOrStop() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                            .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                    .help("Send (Return) · new line: Shift-Return")
                    .disabled(!model.canSend)
                    .frame(width: 30, height: 30)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor)))

            if let t {
                HStack(spacing: 8) {
                    Picker("Model", selection: Binding(get: { t.model }, set: { model.patchThread(["model": .string($0)]) })) {
                        ForEach(model.s.models, id: \.id) { o in Text(o.label).tag(o.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Model for this thread")
                    Picker("Mode", selection: Binding(get: { t.mode }, set: { model.patchThread(["mode": .string($0)]) })) {
                        ForEach(model.s.modes, id: \.id) { o in Text(o.label).tag(o.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help(ClientText.modeHint(t.mode))
                    if t.mode == "full" { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    if t.mode == "commands" { Image(systemName: "terminal.fill").foregroundStyle(.orange) }
                    Text(model.uploading ?? ClientText.modeHint(t.mode))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(t.mode == "full" ? Color.red : t.mode == "commands" ? Color.orange : Color.secondary)
                    Spacer(minLength: 8)
                    if t.cost != 0 { Text(String(format: "$%.4f so far", t.cost)).monospacedDigit().foregroundStyle(.secondary) }
                }
                .controlSize(.small)
                .font(.caption)
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

/// The message box: an NSTextView, which tells Return (send) from Shift-Return (new line) reliably and handles
/// input methods. Grows with its text up to 220 points.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var enabled: Bool
    var focusRequest: Int
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 4, height: 7)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = enabled
        tv.isSelectable = enabled
        if focusRequest != c.lastFocus {
            c.lastFocus = focusRequest
            DispatchQueue.main.async { if enabled { tv.window?.makeFirstResponder(tv) } }
        }
        DispatchQueue.main.async { c.recalc() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocus = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalc()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSend()
            return true
        }

        func recalc() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            let clamped = min(max(h, 32), 220)
            if abs(parent.height - clamped) > 0.5 { parent.height = clamped }
        }
    }
}

// MARK: - inspector: Changes and Network

struct DrawerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: Binding(get: { model.drawer ?? .changes }, set: { tab in
                model.drawer = tab
                if tab == .changes { model.loadDiff() }
            })) {
                Text("Changes").tag(DrawerTab.changes)
                Text("Network").tag(DrawerTab.network)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.drawer == .network { NetworkPanel(model: model) } else { ChangesPanel(model: model) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.s.current?.thread.id ?? "") { _, _ in if model.drawer == .changes { model.loadDiff() } }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

struct ChangesPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.s.current == nil {
            Text("Open a thread to see its project changes.").foregroundStyle(.secondary)
        } else {
            HStack {
                SectionLabel(text: "Status")
                Spacer()
                Button { model.loadDiff() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Refresh")
            }
            switch model.diff {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let msg):
                Text(msg).foregroundStyle(.secondary)
            case .notRepo:
                Text("This project is not a git repository, so there is nothing to diff.").foregroundStyle(.secondary)
            case .loaded(let status, let diff, let truncated):
                PreText(text: status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(clean)" : status.trimmingCharacters(in: .newlines))
                SectionLabel(text: "Diff vs HEAD")
                if diff.isEmpty {
                    Text("No tracked-file changes.").foregroundStyle(.secondary)
                } else {
                    DiffLinesView(lines: DiffLinesView.git(diff))
                }
                if truncated { Text("Diff truncated at 300 KB.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct NetworkPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.s
        Text(s.guardOn
             ? "Everything Claude Code tries to reach goes through a local guard on 127.0.0.1. Only the allowed hosts below are connected; anything else is refused and listed here. (The guard never sees traffic contents — only host and port.)"
             : "The guard is OFF: Claude Code is talking to the network directly. Restart without --no-guard to turn it on.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        SectionLabel(text: "Allowed")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(s.allow, id: \.self) { a in
                Text(a).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
        }
        SectionLabel(text: "Connection attempts")
        let rows = s.networkRows
        if rows.isEmpty {
            Text("Nothing yet. Send a message and any connection Claude Code makes will show up here.").foregroundStyle(.secondary)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
            HStack(spacing: 8) {
                Image(systemName: r.allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(r.allowed ? Color.green : Color.red)
                    .help(r.allowed ? "allowed" : "blocked")
                Text(r.target)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(r.target)
                if r.count > 1 { Text("×\(r.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                if !r.allowed && r.note != "plain http" {
                    Button("Allow") { model.allowHost(r.allowEntry) }
                        .controlSize(.small)
                        .help("Add \(r.allowEntry) to the allow-list")
                }
            }
            .padding(.vertical, 3)
            Divider()
        }
    }
}
#endif
