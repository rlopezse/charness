// Charness.app: the whole Charness server runs inside this app (Swift, CharnessCore) and its web UI is shown
// in ONE WKWebView window. No Node process: Claude Code itself is the only other program it starts.
// Quitting stops the server (and any running turn) and writes what is pending to disk.
// Built by scripts/make-mac-app.sh (swift build); no Xcode project and no third-party code.

#if canImport(AppKit)
import AppKit
import WebKit
import CharnessCore

/// Getting the server going, done off the main thread.
enum Startup {
    /// Apps don't see what you `export` in Terminal: if ANTHROPIC_API_KEY isn't set, read it from the Keychain
    /// (item "charness"). Without one, Claude Code uses its own login on this Mac.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var server: CharnessServer?
    private var port: Int?
    private var tokenURL: URL?
    private var quitting = false

    private let root: String = (Bundle.main.object(forInfoDictionaryKey: "CharnessRoot") as? String) ?? ""

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
            webView.load(URLRequest(url: url))
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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // this app's own store, separate from Safari and Chrome
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            // Opt-in Web Inspector for debugging: defaults write local.charness.app CharnessInspectable -bool true
            webView.isInspectable = UserDefaults.standard.bool(forKey: "CharnessInspectable")
        }
        webView.loadHTMLString(
            "<body style='font:13px -apple-system;color:#888;padding:2em'>Starting Charness…</body>", baseURL: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Charness"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("CharnessMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    private func isOurs(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && port != nil && url.port == port
    }

    private func openOutside(_ url: URL) {
        if let s = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(s) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

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
        if let url = webView.url, isOurs(url) { webView.reload() }
        else if let url = tokenURL { webView.load(URLRequest(url: url)) }
    }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func actualSize(_ sender: Any?) { webView.pageZoom = 1.0 }

    // WKWebView needs a real Edit menu, or Cmd-C / Cmd-V / Cmd-A don't work in text fields.
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

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Reload", #selector(reloadPage(_:)), "r", target: self)
        view.addItem(.separator())
        add(view, "Actual Size", #selector(actualSize(_:)), "0", target: self)
        add(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)

        let win = submenu("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        add(win, "Close", #selector(NSWindow.performClose(_:)), "w")

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
