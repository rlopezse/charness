// The native screens' model: owns the API client and the live-event feed (CharnessCore/Client.swift, tested in
// core-checks) and does what the retired web UI (app.js) did with them — refreshState, openThread, send, approvals — plus
// the UI-only state (drawer, collapsed projects, attachments, toast). The views in this folder only draw it.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import CharnessCore

/// Live events arrive on a background thread; they are queued here in order and applied on the main thread in
/// small batches (a streaming answer sends many tiny events).
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [JSONValue] = []
    private var scheduled = false

    /// True when the caller should schedule a drain.
    func push(_ v: JSONValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items.append(v)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func drain() -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        let out = items
        items = []
        return out
    }
}

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int
}

enum DrawerTab: String { case changes, network }

enum DiffState: Equatable {
    case idle
    case loading
    case failed(String)
    case notRepo
    case loaded(status: String, diff: String, truncated: Bool)
}

@MainActor
final class AppModel: ObservableObject {
    static let maxFileBytes = 25 * 1024 * 1024   // same limits as the server (Uploads.swift)
    static let maxFiles = 10

    let api: APIClient
    private let token: String
    private var stream: EventStream?
    private let inbox = EventInbox()
    private var connectedOnce = false
    private var toastSerial = 0

    @Published private(set) var s = ClientState()
    @Published private(set) var ready = false
    /// Everything the first screen needs has loaded (projects, threads, the last open thread): the launch screen
    /// gives way to the UI. Also set after 15 s whatever happens, so a hang never leaves the launch screen up.
    @Published private(set) var launched = false
    @Published var drawer: DrawerTab?
    @Published var collapsed = Set<String>()
    /// The thread highlighted in the sidebar; set at once on a click, before the thread has loaded.
    @Published var selection: String?
    /// The live feed has connected at least once (so a drop shows "Reconnecting…", the first connect doesn't).
    @Published private(set) var everConnected = false
    @Published var attachments: [Attachment] = []
    @Published var draft = ""
    @Published var openTools = Set<String>()
    @Published private(set) var toast: String?
    @Published private(set) var uploading: String?
    @Published private(set) var diff = DiffState.idle
    /// Bumped when what the open thread shows changes (to follow the bottom while it streams).
    @Published private(set) var contentVersion = 0
    /// Bumped to jump to the bottom whatever the scroll position (opening a thread, a new approval card).
    @Published private(set) var scrollRequest = 0
    /// Bumped to put the cursor in the message box.
    @Published private(set) var focusRequest = 0

    init(port: Int, token: String) {
        api = APIClient(port: port)
        self.token = token
    }

    // MARK: running work off the main thread

    /// Runs `work` in the background; `done` gets its result on the main thread, errors become a toast.
    private func background<T>(_ work: @escaping @Sendable () async throws -> T, failed: (@MainActor (Error) -> Void)? = nil,
                               done: @escaping @MainActor (T) -> Void) {
        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                let value = try await work()
                await MainActor.run { done(value) }
            } catch {
                await MainActor.run {
                    if let failed { failed(error) } else { model.showToast("\(error)") }
                }
            }
        }
    }

    func showToast(_ text: String) {
        toastSerial += 1
        let mine = toastSerial
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self?.toastSerial == mine { self?.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: start / stop

    func start() {
        let api = self.api, token = self.token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.launched = true
        }
        background({ () -> JSONValue in
            try api.login(token: token)
            return try api.request("GET", "/api/state")
        }, failed: { [weak self] e in
            self?.ready = true
            self?.launched = true
            self?.showToast("\(e)")
        }) { [weak self] state in
            guard let self else { return }
            s.applyState(state)
            ready = true
            let last = UserDefaults.standard.string(forKey: "CharnessLastThread")
            let pick = s.threads.first { $0.id == last } ?? s.threads.max { $0.updatedAt < $1.updatedAt }
            if let pick { openThread(pick.id, then: { [weak self] in self?.launched = true }) } else { launched = true }
            startStream()
        }
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    private func startStream() {
        let inbox = self.inbox
        let st = EventStream(client: api, onEvent: { [weak self] ev in
            if inbox.push(ev) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    self?.drainEvents()
                }
            }
        }, onConnection: { [weak self] up in
            Task { @MainActor [weak self] in self?.connectionChanged(up) }
        })
        stream = st
        st.start()
    }

    private func connectionChanged(_ up: Bool) {
        s.connected = up
        guard up else { return }
        everConnected = true
        if connectedOnce { resync() }   // events may have been missed while it was down
        connectedOnce = true
    }

    /// Re-reads everything (after a reconnect, or View ▸ Reload).
    func resync() {
        refreshState()
        if let id = s.current?.thread.id { openThread(id, keepScroll: true) }
    }

    private func drainEvents() {
        let events = inbox.drain()
        guard !events.isEmpty else { return }
        let openId = s.current?.thread.id
        var changed = false
        var jump = false
        var refresh = false
        var next = s
        for ev in events {
            let o = ev.objectValue ?? JSONObject()
            let threadId = o["threadId"]?.stringValue ?? o["perm"]?.objectValue?["threadId"]?.stringValue
            if next.handle(ev) == .refreshState { refresh = true }
            if let openId, threadId == openId { changed = true }
            if o["type"] == "perm", threadId == openId { jump = true }
            if o["type"] == "perm_done" { changed = true }
        }
        s = next
        if changed { contentVersion += 1 }
        if jump { scrollRequest += 1 }
        if refresh { refreshState() }
    }

    // MARK: data flow (app.js)

    func refreshState() {
        let api = self.api
        background({ try api.request("GET", "/api/state") }) { [weak self] v in
            guard let self else { return }
            let before = s.current?.thread.id
            s.applyState(v)
            if before != nil && s.current == nil { contentVersion += 1; selection = nil }
        }
    }

    /// Loads a thread; `then` runs once it has loaded (or failed to).
    func openThread(_ id: String, keepScroll: Bool = false, then: (@MainActor () -> Void)? = nil) {
        selection = id
        let api = self.api
        background({ try api.request("GET", "/api/threads/\(id)") }, failed: { [weak self] e in
            defer { then?() }
            guard let self else { return }
            if selection == id { selection = s.current?.thread.id }   // don't stay on "Loading…"
            showToast("\(e)")
        }) { [weak self] v in
            defer { then?() }
            guard let self else { return }
            let switching = s.current?.thread.id != id
            s.applyThread(v)
            UserDefaults.standard.set(id, forKey: "CharnessLastThread")
            if switching {
                attachments = []         // picked files belong to the thread they were picked in
                if drawer == .changes { loadDiff() }
            }
            contentVersion += 1
            if !keepScroll { scrollRequest += 1; focusRequest += 1 }
        }
    }

    func newThread(_ projectId: String) {
        let api = self.api
        background({ try api.request("POST", "/api/threads", ["projectId": .string(projectId)]) }) { [weak self] t in
            guard let self, let id = t.text("id").nilIfEmpty else { return }
            collapsed.remove(projectId)
            refreshState()
            openThread(id)
        }
    }

    /// ⌘N: a new thread in the open thread's project (or the first project).
    func newThreadHere() {
        if let p = s.current?.thread.projectId ?? s.projects.first?.id { newThread(p) }
    }

    func addProject(_ path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let api = self.api
        background({ try api.request("POST", "/api/projects", ["path": .string(path)]) }) { [weak self] p in
            guard let self, let id = p.text("id").nilIfEmpty else { return }
            newThread(id)
        }
    }

    /// Asks for a folder and adds it as a project.
    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Choose the folder Claude will work in"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK, let url = panel.url { self?.addProject(url.path) }
        }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func deleteProject(_ id: String) {
        let api = self.api
        background({ try api.request("DELETE", "/api/projects/\(id)") }) { [weak self] _ in self?.refreshState() }
    }

    func deleteThread(_ id: String) {
        let api = self.api
        background({ try api.request("DELETE", "/api/threads/\(id)") }) { [weak self] _ in self?.refreshState() }
    }

    func renameThread(_ id: String, _ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let api = self.api
        background({ try api.request("PATCH", "/api/threads/\(id)", ["title": .string(title)]) }) { [weak self] _ in self?.refreshState() }
    }

    func patchThread(_ fields: JSONObject) {
        guard let id = s.current?.thread.id else { return }
        let api = self.api
        background({ try api.request("PATCH", "/api/threads/\(id)", .object(fields)) }) { [weak self] _ in self?.refreshState() }
    }

    // MARK: composer

    /// A thread was picked (or is being reopened at launch) and hasn't loaded yet.
    var loadingThread: Bool { selection != nil && selection != s.current?.thread.id }

    var isBusy: Bool { s.current.map { s.busy.contains($0.thread.id) } ?? false }

    var canSend: Bool {
        s.current != nil && uploading == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to your message"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK { self?.attach(panel.urls) }
        }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func attach(_ urls: [URL]) {
        var skipped: [String] = []
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let name = url.lastPathComponent
            if size > Self.maxFileBytes { skipped.append("\(name) is larger than 25 MB") }
            else if attachments.count >= Self.maxFiles { skipped.append("at most \(Self.maxFiles) files per message") }
            else { attachments.append(Attachment(url: url, name: name, size: size)) }
        }
        if !skipped.isEmpty {
            var seen = Set<String>()
            showToast("Not attached: " + skipped.filter { seen.insert($0).inserted }.joined(separator: "; "))
        }
        focusRequest += 1
    }

    func removeAttachment(_ a: Attachment) { attachments.removeAll { $0.id == a.id } }

    /// Send (or Stop while Claude works), as onSendClick() in app.js.
    func sendOrStop() {
        guard let t = s.current?.thread, uploading == nil else { return }
        let api = self.api, tid = t.id
        if s.busy.contains(tid) {
            background({ try api.request("POST", "/api/threads/\(tid)/stop") }) { _ in }
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        draft = ""
        attachments = []
        scrollRequest += 1
        if !files.isEmpty { uploading = "Uploading 1/\(files.count)…" }
        let model = self
        background({ () async throws -> Void in
            var names: [JSONValue] = []
            for (i, f) in files.enumerated() {
                await MainActor.run { model.uploading = "Uploading \(i + 1)/\(files.count)…" }
                let bytes: [UInt8]
                do { bytes = [UInt8](try Data(contentsOf: f.url)) } catch {
                    throw APIError(status: 0, message: "\(f.name): can't read the file (\(error.localizedDescription))")
                }
                let r = try api.upload(threadId: tid, name: f.name, bytes: bytes)
                names.append(.string(r.text("name")))
            }
            var body: JSONObject = ["text": .string(text)]
            if !names.isEmpty { body["files"] = .array(names) }
            try api.request("POST", "/api/threads/\(tid)/send", .object(body))
        }, failed: { [weak self] e in
            guard let self else { return }
            uploading = nil
            if draft.isEmpty { draft = text }          // give the message back so nothing is lost
            if attachments.isEmpty { attachments = files }
            showToast("\(e)")
        }) { [weak self] _ in
            self?.uploading = nil
        }
    }

    // MARK: approvals, network, changes

    func answer(_ p: PendingPermission, allow: Bool) {
        var next = s
        next.handle(["type": "perm_done", "id": .string(p.id)])   // hide the card at once, like app.js
        s = next
        contentVersion += 1
        let api = self.api
        background({ try api.request("POST", "/api/permissions/\(p.id)", ["allow": .bool(allow)]) }) { _ in }
    }

    func allowHost(_ entry: String) {
        let api = self.api
        background({ try api.request("POST", "/api/net/allow", ["host": .string(entry)]) }) { [weak self] r in
            guard let self else { return }
            var next = s
            next.handle(["type": "allow", "allow": r.objectValue?["allow"] ?? .array([])])
            s = next
        }
    }

    func toggleDrawer(_ tab: DrawerTab) {
        drawer = drawer == tab ? nil : tab
        if drawer == .changes { loadDiff() }
    }

    func loadDiff() {
        guard let id = s.current?.thread.id else { diff = .idle; return }
        diff = .loading
        let api = self.api
        background({ try api.request("GET", "/api/threads/\(id)/diff") }, failed: { [weak self] e in
            self?.diff = .failed("\(e)")
        }) { [weak self] v in
            guard let self, s.current?.thread.id == id else { return }
            let o = v.objectValue ?? JSONObject()
            if o["isRepo"] != true { diff = .notRepo; return }
            diff = .loaded(status: v.text("status"), diff: v.text("diff"), truncated: o["truncated"] == true)
        }
    }

    func toggleTool(_ id: String) {
        if openTools.contains(id) { openTools.remove(id) } else { openTools.insert(id) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
