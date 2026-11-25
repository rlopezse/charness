// The Charness server in Swift, as a command-line program: the same flags and output as `node server.mjs`.
//     swift run --package-path mac charness-server [--port 4317] [--mock] [--no-guard] [--rotate-token] [--open]
//     [--root DIR]   the Charness folder (public/ and node_modules/); default: the one this was built from
// Charness.app runs the same server inside the app; this program is for the terminal and for test/smoke.mjs
// (CHARNESS_SERVER=<path to this binary> node test/smoke.mjs).

import Foundation
import CharnessCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains(n) }
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let defaultRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
var config = ServerConfig(root: opt("--root").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot)
if let p = opt("--port") { config.port = Int(p) ?? config.port }
if flag("--mock") { config.mock = true }
if flag("--no-guard") { config.guardOn = false }
config.rotateToken = flag("--rotate-token")

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let server: CharnessServer
do { server = try CharnessServer(config: config) } catch { fail("Charness couldn't start: \(error)") }
do { try server.start() } catch {
    if case StoreError.io(_, _, let code) = error, code == EADDRINUSE {
        fail("Port \(config.port) is busy. Try: charness-server --port 4400")
    }
    fail("Charness couldn't start: \(error)")
}

print("\nCharness\(config.mock ? " (MOCK mode — no real model)" : "")")
print("  open:   \(server.link)")
print("  data:   \(config.home.path)")
if let gp = server.guardPort {
    print("  egress: guarded via 127.0.0.1:\(gp), allowed = \(server.allowedHosts().joined(separator: ", "))\n")
} else {
    print("  egress: NOT guarded (--no-guard)\n")
}
fflush(stdout)

if flag("--open") {
    let p = Process()
    #if os(macOS)
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    #else
    p.executableURL = URL(fileURLWithPath: ClaudeLaunch.which("xdg-open") ?? "/usr/bin/xdg-open")
    #endif
    p.arguments = [server.link]
    try? p.run()
}

// Ctrl-C / kill: stop the runs, write what is pending, exit (shutdown() in server.mjs)
var signals: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { server.stop(); exit(0) }
    source.resume()
    signals.append(source)
}
dispatchMain()
