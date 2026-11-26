// Charness.app: the whole Charness server runs inside this app (CharnessCore, on loopback only), shown in ONE
// window of native SwiftUI screens (RootView, talking to the server through Client.swift). The app carries its
// own copy of Claude Code (Contents/MacOS/claude, put there by scripts/make-mac-app.sh): it is the only other
// program it starts. Quitting stops the server (and any running turn) and writes what is pending to disk.
// Built by scripts/make-mac-app.sh (swift build); no Xcode project and no third-party code.
//
// Mock mode (no Claude, no API key, for trying the screens): open -a Charness --args --mock
// (or: defaults write local.charness.app CharnessMock -bool true)

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
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

    /// The Claude Code inside the app (nil when run from `swift run`: then HARNESS_CLAUDE_BIN or `claude` on PATH).
    static var bundledClaude: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("claude").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var mock: Bool {
        CommandLine.arguments.contains("--mock") || UserDefaults.standard.bool(forKey: "CharnessMock")
    }

    /// Starts the server on the first free port from 4317.
    static func start() -> Result<CharnessServer, Error> {
        var config = ServerConfig(environment: environment())
        config.claudeExecutable = bundledClaude
        if mock { config.mock = true }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var model: AppModel?
    private var server: CharnessServer?
    private var quitting = false

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

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
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Startup.start() }.value
            self.serverStarted(result)
        }
    }

    // Clicking the Dock icon brings the single window back instead of opening another one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // Closing the window keeps the server running; Cmd-Q stops it.
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
            let m = AppModel(port: s.port, token: s.token)
            model = m
            let hosting = NSHostingController(rootView: RootView(model: m))
            hosting.sceneBridgingOptions = [.toolbars, .title]   // SwiftUI's toolbar and title go to this window
            setContent(hosting)
            m.start()
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
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Charness"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        setContent(NSHostingController(rootView: StartingView()))
        window.center()
        window.setFrameAutosaveName("CharnessMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    /// Swaps what the window shows, keeping its size and place (a hosting controller would resize the window to
    /// its own size otherwise).
    private func setContent<V: View>(_ hosting: NSHostingController<V>) {
        let frame = window.frame
        hosting.sizingOptions = []
        window.toolbar = nil
        window.contentViewController = hosting
        window.setFrame(frame, display: true)
    }

    // MARK: menu actions

    @objc func reloadPage(_ sender: Any?) { model?.resync() }
    @objc func newThread(_ sender: Any?) { model?.newThreadHere() }
    @objc func addProject(_ sender: Any?) { model?.chooseProjectFolder() }
    @objc func toggleChanges(_ sender: Any?) { model?.toggleDrawer(.changes) }
    @objc func toggleNetwork(_ sender: Any?) { model?.toggleDrawer(.network) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(newThread(_:)):
            return model != nil && !(model?.s.projects.isEmpty ?? true)
        case #selector(addProject(_:)), #selector(toggleChanges(_:)), #selector(toggleNetwork(_:)), #selector(reloadPage(_:)):
            return model != nil
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

        let win = submenu("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), "")

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

// Top-level code runs on the main thread, but Swift 5 mode doesn't treat it as main-actor code: say so.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()   // NSApplication holds its delegate weakly; run() never returns, so this lives
    app.delegate = delegate
    app.run()
}
#else
print("Charness.app is macOS-only. Its core builds and is tested on Linux: swift run --package-path mac core-checks")
#endif
