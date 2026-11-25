// The PATH of the user's login shell, for Charness.app. Apps opened from Finder or the Dock get a bare PATH
// (/usr/bin:/bin:/usr/sbin:/sbin), so the commands Claude runs wouldn't find Homebrew, nvm, pyenv… tools that
// work in Terminal. At launch the app asks the shell once (time-boxed) and passes that PATH to the server, which
// gives it to Claude Code. Only PATH is taken from the shell; nothing else of its environment is.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ShellPath {
    static let start = "__CHARNESS_PATH_START__"
    static let end = "__CHARNESS_PATH_END__"

    /// The PATH between the markers; shell start-up files may print other things around it.
    public static func parse(_ output: String) -> String? {
        guard let a = output.range(of: start), let b = output.range(of: end, range: a.upperBound..<output.endIndex) else { return nil }
        let path = String(output[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The shell's entries first, then any of the current ones it lacks; no duplicates or empty entries.
    public static func merge(shell: String?, current: String?) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for part in (shell ?? "").split(separator: ":") + (current ?? "").split(separator: ":") {
            let p = String(part)
            if !p.isEmpty && seen.insert(p).inserted { out.append(p) }
        }
        return out.joined(separator: ":")
    }

    /// Runs `shell -i -l -c` (interactive login shell, so .zprofile and .zshrc both count, as in Terminal) and
    /// returns its PATH, or nil if the shell fails, prints no PATH, or takes longer than `timeout` seconds.
    public static func fromLoginShell(_ shell: String, timeout: Double = 5, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-i", "-l", "-c", "printf '%s%s%s' '\(start)' \"$PATH\" '\(end)'"]
        var env = environment
        env["CHARNESS_PATH_PROBE"] = "1"         // lets a start-up file skip slow work if it wants to
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }

        do { try p.run() } catch { return nil }        // (Process closes our copy of the pipe's write end)
        let lock = NSLock()
        var data = Data()
        let reader = out.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let chunk = reader.availableData          // empty at end of file
                if chunk.isEmpty { break }
                lock.lock(); data.append(chunk); lock.unlock()
            }
            drained.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // the shell hangs (a start-up file waiting for something): stop it and do without
            kill(p.processIdentifier, SIGKILL)
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)            // a child it left behind may hold the pipe open
        lock.lock(); let text = String(decoding: data, as: UTF8.self); lock.unlock()
        return p.terminationStatus == 0 ? parse(text) : nil
    }
}
