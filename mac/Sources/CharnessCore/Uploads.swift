// Files attached to a message. Kept per thread in <data>/uploads/<threadId>/
// (folders 0700, files 0600), outside the project so nothing lands in the user's repo. Claude gets read access
// to that folder (--add-dir) and the message lists the files' paths. Never served back over HTTP.
//
// Paths are built as plain strings, not with URL: on macOS, URL hands file names to the system in decomposed
// Unicode ("ñ" as "n" + "~"), so "foto ñ.png" would be stored under different bytes than Node stores it.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct Uploads {
    public static let maxFileBytes = 25 * 1024 * 1024
    public static let maxFilesPerMessage = 10

    public let root: String

    public init(home: URL) { root = home.path + "/uploads" }

    /// The thread's upload folder. Thread ids are lowercase hex (checked by the caller), so this stays in root.
    public func dir(_ threadId: String) -> String { root + "/" + threadId }

    /// A file name that is safe to store: no folders, no control characters, no hidden files, not too long.
    /// Same rules as safeName() in the retired lib/uploads.mjs.
    public static func safeName(_ raw: String) -> String {
        var n = String(raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
        let bad: Set<Unicode.Scalar> = ["<", ">", ":", "\"", "|", "?", "*"]
        n = String(String.UnicodeScalarView(n.unicodeScalars.map { u in
            (u.value < 0x20 || u.value == 0x7F || bad.contains(u)) ? "_" : u
        }))
        // drop leading dots and whitespace, then trim (JS \s and String.trim())
        let scalars = Array(n.unicodeScalars)
        let start = scalars.firstIndex { !($0 == "." || jsSpace($0)) } ?? scalars.count
        n = String(String.UnicodeScalarView(scalars[start...])).trimmingJSSpace()
        if n.utf16.count > 120 {
            let ext = JS.prefix(extname(n), 16)
            n = JS.prefix(n, 120 - ext.utf16.count).trimmingJSSpace(leading: false) + ext
        }
        return n.isEmpty ? "file" : n
    }

    /// path.extname(): from the last "." of the name, unless that dot is its first character.
    static func extname(_ n: String) -> String {
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
        return String(n[dot...])
    }

    static func jsSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// Stores the bytes under a free name ("notes.txt", then "notes (2).txt"...). Returns (name, size).
    public func save(_ threadId: String, name rawName: String, bytes: [UInt8]) throws -> (name: String, size: Int) {
        let folder = dir(threadId)
        try Files.makeDirectories(URL(fileURLWithPath: folder, isDirectory: true))   // hex names only: safe as a URL
        let name = Uploads.safeName(rawName)
        let ext = Uploads.extname(name)
        let base = String(name.dropLast(ext.count)).isEmpty ? name : String(name.dropLast(ext.count))
        for n in 1..<1000 {
            let candidate = n == 1 ? name : "\(base) (\(n))\(ext)"
            let path = folder + "/" + candidate
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw StoreError.io(path: path, operation: "open", code: errno)
            }
            defer { _ = close(fd) }
            if !Net.writeAll(fd, bytes) { throw StoreError.io(path: path, operation: "write", code: errno) }
            return (candidate, bytes.count)
        }
        throw StoreError.io(path: folder, operation: "save (too many files with that name)", code: EEXIST)
    }

    /// (name, size, path) of a file stored for this thread, or nil (unknown name, folder tricks, not a file).
    public func find(_ threadId: String, _ name: JSONValue) -> (name: String, size: Int, path: String)? {
        guard case .string(let n) = name, !n.isEmpty, n == Uploads.safeName(n) else { return nil }
        let path = dir(threadId) + "/" + n
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (n, Int(st.st_size), path)
    }

    /// The folder to give Claude read access to, if this thread has any files.
    public func folderIfAny(_ threadId: String) -> String? {
        FileManager.default.fileExists(atPath: dir(threadId)) ? dir(threadId) : nil
    }

    /// Deletes the thread's files (when the thread or its project is deleted).
    public func removeAll(_ threadId: String) {
        try? FileManager.default.removeItem(atPath: dir(threadId))
    }
}

extension String {
    /// String.prototype.trim() (or trimEnd() with leading: false), with JavaScript's idea of whitespace.
    func trimmingJSSpace(leading: Bool = true) -> String {
        var s = Array(unicodeScalars)
        while let last = s.last, Uploads.jsSpace(last) { s.removeLast() }
        if leading { while let first = s.first, Uploads.jsSpace(first) { s.removeFirst() } }
        return String(String.UnicodeScalarView(s))
    }
}

extension Net {
    /// write() all bytes to a file descriptor (a file, not a socket).
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { cWrite(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }
}

#if canImport(Darwin)
private let cWrite: (Int32, UnsafeRawPointer?, Int) -> Int = Darwin.write
#else
private let cWrite: (Int32, UnsafeRawPointer?, Int) -> Int = Glibc.write
#endif
