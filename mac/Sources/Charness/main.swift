// Charness.app: a native macOS window around the existing Node server.
//
// It starts the server with scripts/launch.sh (the same start/stop logic the old AppleScript applet used),
// shows the UI in ONE WKWebView window instead of a Chrome window per launch, and stops the server on Quit.
// Built by scripts/make-mac-app.sh (swift build); no Xcode project and no third-party code.

#if canImport(AppKit)
import AppKit
import WebKit

struct LaunchResult {
    let status: Int32
    let output: String
}

// Runs `launch.sh <command>` and waits for it. Kept outside the app delegate so it can run off the main thread.
enum Launcher {
    static func run(_ script: String, _ command: String) -> LaunchResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, command]
        var env = ProcessInfo.processInfo.environment
        env["HARNESS_LAUNCH_NO_UI"] = "1"   // launch.sh must not open a browser; this app is the window
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return LaunchResult(status: -1, output: "Could not run \(script): \(error.localizedDescription)")
        }
        // launch.sh sends the server's own output to ~/.charness/server.log, so this pipe closes when the script exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return LaunchResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var port: Int?
    private var tokenURL: URL?
    private var quitting = false

    private let root: String = (Bundle.main.object(forInfoDictionaryKey: "CharnessRoot") as? String) ?? ""
    private var launcher: String { root + "/scripts/launch.sh" }
    private let dataDir: String = {
        if let h = ProcessInfo.processInfo.environment["HARNESS_HOME"], !h.isEmpty { return h }
        return NSHomeDirectory() + "/.charness"
    }()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        guard !root.isEmpty, FileManager.default.fileExists(atPath: launcher) else {
            fail("Charness couldn't start",
                 "The project folder was not found (\(root.isEmpty ? "not set" : root)). "
                 + "Re-run scripts/make-mac-app.sh from the charness folder.")
            return
        }

        let script = launcher
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Launcher.run(script, "start") }.value
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
        let script = launcher
        Task { @MainActor in
            _ = await Task.detached(priority: .userInitiated) { Launcher.run(script, "stop") }.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func serverStarted(_ r: LaunchResult) {
        guard r.status == 0, let url = readServerURL() else {
            let msg = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            fail("Charness couldn't start", msg.isEmpty ? "See \(dataDir)/server.log" : msg)
            return
        }
        tokenURL = url
        webView.load(URLRequest(url: url))
    }

    // launch.sh writes the port; the server writes the token. The token is base64url, but encode it anyway.
    private func readServerURL() -> URL? {
        func read(_ name: String) -> String? {
            guard let s = try? String(contentsOfFile: dataDir + "/" + name, encoding: .utf8) else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let p = read("server.port").flatMap(Int.init), let token = read("token") else { return nil }
        port = p
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let enc = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        return URL(string: "http://127.0.0.1:\(p)/?token=\(enc)")
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if tokenURL == nil || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { return }
        webView.loadHTMLString(
            "<body style='font:13px -apple-system;color:#888;padding:2em'>Can't reach the Charness server "
            + "(\(error.localizedDescription)).<br>Press ⌘R to retry, or quit and reopen the app. "
            + "Log: \(dataDir)/server.log</body>", baseURL: nil)
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
