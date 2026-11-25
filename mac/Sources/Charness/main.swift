// Charness.app: the whole Charness server runs inside this app (Swift, CharnessCore), shown in ONE window with
// native SwiftUI screens (RootView, talking to the server over loopback like the web UI does). The web UI is still
// there behind View ▸ Use Web Interface, in a WKWebView, as a fallback.
// No Node process: Claude Code itself is the only other program it starts.
// Quitting stops the server (and any running turn) and writes what is pending to disk.
// Built by scripts/make-mac-app.sh (swift build); no Xcode project and no third-party code.

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import WebKit
import CharnessCore

/// Getting the server going, done off the main thread.
enum Startup {
    /// Apps don't see what you `export` in Terminal: if ANTHROPIC_API_KEY isn't set, read it from the Keychain
    /// (item "charness"). Without one, Claude Code uses its own login on this Mac.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Apps opened from Finder get a bare PATH; take the login shell's (Homebrew, nvm…) so Claude's commands
        // find the same tools as in Terminal. Off with: defaults write local.charness.app CharnessShellPath -bool false
        if UserDefaults.standard.object(forKey: "CharnessShellPath") as? Bool ?? true {
            let shell = env["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            if let path = ShellPath.fromLoginShell(shell, timeout: 5, environment: env) {
                env["PATH"] = ShellPath.merge(shell: path, current: env["PATH"])
            }
        }
        guard (env["ANTHROPIC_API_KEY"] ?? "").isEmpty else { return env }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "charness", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return env }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus == 0 && !key.isEmpty { env["ANTHROPIC_API_KEY"] = key }
        return env
    }

    /// Starts the server on the first free port from 4317.
    static func start(root: String) -> Result<CharnessServer, Error> {
        var config = ServerConfig(root: URL(fileURLWithPath: root, isDirectory: true), environment: environment())
        let first = config.port
        for port in first...(first + 20) {
            config.port = port
            do {
                let server = try CharnessServer(config: config)
                try server.start()
                return .success(server)
            } catch StoreError.io(_, _, let code) where code == EADDRINUSE {
                continue
            } catch {
                return .failure(error)
            }
        }
        return .failure(StoreError.io(path: "127.0.0.1:\(first)-\(first + 20)", operation: "listen (no free port)", code: EADDRINUSE))
    }
}

/// Shown while the server starts.
struct StartingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Starting Charness…").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView?
    private var model: AppModel?
    private var server: CharnessServer?
    private var port: Int?
    private var tokenURL: URL?
    private var quitting = false

    private let root: String = (Bundle.main.object(forInfoDictionaryKey: "CharnessRoot") as? String) ?? ""

    /// View ▸ Use Web Interface (remembered). Off = the native screens.
    private var useWebUI: Bool {
        get { UserDefaults.standard.bool(forKey: "CharnessUseWebUI") }
        set { UserDefaults.standard.set(newValue, forKey: "CharnessUseWebUI") }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        guard !root.isEmpty, FileManager.default.fileExists(atPath: root + "/public/index.html") else {
            fail("Charness couldn't start",
                 "The Charness folder was not found (\(root.isEmpty ? "not set" : root)). "
                 + "Re-run scripts/make-mac-app.sh from the charness folder.")
            return
        }

        let others = otherCopies()
        guard !others.isEmpty else { return startServer() }
        // Two copies (say an older build somewhere else) would run two servers on the same data (~/.charness).
        let alert = NSAlert()
        alert.messageText = "Charness is already running"
        alert.informativeText = "Another copy of Charness is open:\n"
            + others.map { $0.bundleURL?.path ?? "pid \($0.processIdentifier)" }.joined(separator: "\n")
            + "\n\nBoth would use the same data, so only one can run. Quit the other copy and continue with this one?"
        alert.addButton(withTitle: "Quit Other Copy")
        alert.addButton(withTitle: "Quit This One")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        for o in others { o.terminate() }       // a normal quit: it stops its server and saves what is pending
        Task { @MainActor in
            for _ in 0..<150 where !self.otherCopies().isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            if self.otherCopies().isEmpty { self.startServer() }
            else { self.fail("The other copy of Charness didn't quit", "Quit it yourself (Cmd-Q in its window), then open this one again.") }
        }
    }

    /// Other running copies of this app (same bundle id), wherever they are installed.
    private func otherCopies() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.charness.app")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    private func startServer() {
        let root = self.root
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Startup.start(root: root) }.value
            self.serverStarted(result)
        }
    }

    // Clicking the Dock icon brings the single window back instead of opening another one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // Closing the window keeps the server running (as before); Cmd-Q stops it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateCancel }   // a stop is already in progress; that one will finish the quit
        quitting = true
        window?.orderOut(nil)
        model?.stop()
        let running = server
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { running?.stop() }.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func serverStarted(_ result: Result<CharnessServer, Error>) {
        switch result {
        case .failure(let error):
            fail("Charness couldn't start", "\(error)")
        case .success(let s):
            server = s
            port = s.port
            guard let url = URL(string: s.link) else { return fail("Charness couldn't start", "Bad address: \(s.link)") }
            tokenURL = url
            showInterface()
        }
    }

    private func fail(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Charness"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        setContent(NSHostingController(rootView: StartingView()), native: true)
        window.center()
        window.setFrameAutosaveName("CharnessMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    /// Puts the chosen interface in the window: the native screens, or the web UI in a WKWebView.
    private func showInterface() {
        guard let server, let url = tokenURL else { return }
        if useWebUI {
            model?.stop()
            model = nil
            let web = webView ?? makeWebView()
            webView = web
            let vc = NSViewController()
            vc.view = web
            setContent(vc, native: false)
            web.load(URLRequest(url: url))
        } else {
            webView = nil
            model?.stop()
            let m = AppModel(port: server.port, token: server.token)
            model = m
            let hosting = NSHostingController(rootView: RootView(model: m))
            hosting.sceneBridgingOptions = [.toolbars, .title]   // SwiftUI's toolbar and title go to this window
            setContent(hosting, native: true)
            m.start()
        }
    }

    /// Swaps what the window shows, keeping its size and place. The native screens use the whole window
    /// (sidebar under the title bar, toolbar in it); the web page sits below a plain title bar.
    private func setContent(_ vc: NSViewController, native: Bool) {
        let frame = window.frame
        if let hosting = vc as? NSHostingController<RootView> { hosting.sizingOptions = [] }
        if let hosting = vc as? NSHostingController<StartingView> { hosting.sizingOptions = [] }
        if native { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        window.toolbar = nil
        window.contentViewController = vc
        if !native { window.title = "Charness"; window.subtitle = "" }
        window.setFrame(frame, display: true)
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // this app's own store, separate from Safari and Chrome
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            // Opt-in Web Inspector for debugging: defaults write local.charness.app CharnessInspectable -bool true
            web.isInspectable = UserDefaults.standard.bool(forKey: "CharnessInspectable")
        }
        return web
    }

    private func isOurs(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && port != nil && url.port == port
    }

    private func openOutside(_ url: URL) {
        if let s = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(s) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate (web interface only)

    // The window only ever shows our own server. Links elsewhere go to the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || isOurs(url) { return decisionHandler(.allow) }
        if navigationAction.navigationType == .linkActivated { openOutside(url) }
        decisionHandler(.cancel)
    }

    // target="_blank" links (Markdown links in chat) open in the default browser, never in a new window here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !isOurs(url) { openOutside(url) }
        return nil
    }

    // <input type="file"> (the 📎 button): a WKWebView shows no file picker unless the app provides one.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to your message"
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if tokenURL == nil || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { return }
        webView.loadHTMLString(
            "<body style='font:13px -apple-system;color:#888;padding:2em'>Can't reach the Charness server "
            + "(\(error.localizedDescription)).<br>Press ⌘R to retry, or quit and reopen the app.</body>", baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadPage(nil)
    }

    // MARK: menu actions

    @objc func reloadPage(_ sender: Any?) {
        if let model { model.resync(); return }
        guard let web = webView else { return }
        if let url = web.url, isOurs(url) { web.reload() }
        else if let url = tokenURL { web.load(URLRequest(url: url)) }
    }
    @objc func zoomIn(_ sender: Any?) { if let w = webView { w.pageZoom = min(w.pageZoom + 0.1, 3.0) } }
    @objc func zoomOut(_ sender: Any?) { if let w = webView { w.pageZoom = max(w.pageZoom - 0.1, 0.5) } }
    @objc func actualSize(_ sender: Any?) { webView?.pageZoom = 1.0 }
    @objc func toggleWebUI(_ sender: Any?) {
        useWebUI.toggle()
        showInterface()
    }
    @objc func newThread(_ sender: Any?) { model?.newThreadHere() }
    @objc func addProject(_ sender: Any?) { model?.chooseProjectFolder() }
    @objc func toggleChanges(_ sender: Any?) { model?.toggleDrawer(.changes) }
    @objc func toggleNetwork(_ sender: Any?) { model?.toggleDrawer(.network) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(toggleWebUI(_:)):
            item.state = useWebUI ? .on : .off
            return server != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)):
            return webView != nil
        case #selector(newThread(_:)):
            return model != nil && !(model?.s.projects.isEmpty ?? true)
        case #selector(addProject(_:)), #selector(toggleChanges(_:)), #selector(toggleNetwork(_:)):
            return model != nil
        case #selector(reloadPage(_:)):
            return server != nil
        default:
            return true
        }
    }

    // A real Edit menu, or Cmd-C / Cmd-V / Cmd-A don't work in text fields.
    private func buildMenu() {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }

        let app = submenu("Charness")
        add(app, "About Charness", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(.separator())
        add(app, "Hide Charness", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        add(app, "Quit Charness", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "New Thread", #selector(newThread(_:)), "n", target: self)
        add(file, "Add Project…", #selector(addProject(_:)), "o", target: self)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Changes", #selector(toggleChanges(_:)), "1", [.command, .option], target: self)
        add(view, "Network", #selector(toggleNetwork(_:)), "2", [.command, .option], target: self)
        view.addItem(.separator())
        add(view, "Reload", #selector(reloadPage(_:)), "r", target: self)
        view.addItem(.separator())
        add(view, "Actual Size", #selector(actualSize(_:)), "0", target: self)
        add(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        view.addItem(.separator())
        add(view, "Use Web Interface", #selector(toggleWebUI(_:)), "", target: self)

        let win = submenu("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), "")

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#else
print("Charness.app is macOS-only. On other systems, use `npm start`.")
#endif
