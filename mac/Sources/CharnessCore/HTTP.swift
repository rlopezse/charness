// A small HTTP/1.1 server for the Swift Charness server: loopback only, one thread per connection, one request
// per connection (the answer says "Connection: close"), request bodies by Content-Length or chunked, and
// streamed answers for the live-event feed (Server-Sent Events). No third-party code.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPRequest {
    public let method: String
    /// The request target as sent, e.g. "/api/threads/abc?x=1".
    public let target: String
    /// Header names in lowercase. Repeated headers are joined (cookies with "; ", others with ", ").
    public let headers: [String: String]
    public let body: [UInt8]
    /// The body was larger than the server's limit; `body` is empty and the rest was read and dropped.
    public let bodyTooLarge: Bool

    public var path: String {
        let p = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        return p.isEmpty ? "/" : p
    }

    /// A query parameter, decoded (nil if absent).
    public func query(_ name: String) -> String? {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            if k == name {
                let v = kv.count > 1 ? String(kv[1]) : ""
                return v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? v
            }
        }
        return nil
    }
}

/// Where a handler writes its answer: once with `send`, or as a stream with `startStream` + `write`.
public final class HTTPResponse: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var streaming = false
    /// Headers added to every answer (security headers).
    var baseHeaders: [(String, String)] = []
    let isHead: Bool

    init(fd: Int32, isHead: Bool) { self.fd = fd; self.isHead = isHead }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return status >= 500 ? "Internal Server Error" : "Status"
        }
    }

    private func head(_ status: Int, _ headers: [(String, String)], extra: [(String, String)]) -> String {
        var s = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (k, v) in baseHeaders + headers + extra { s += "\(k): \(v)\r\n" }
        return s + "\r\n"
    }

    /// The whole answer at once. Later calls are ignored.
    public func send(_ status: Int, _ headers: [(String, String)] = [], _ body: [UInt8] = []) {
        lock.lock(); defer { lock.unlock() }
        if finished || streaming { return }
        finished = true
        let h = head(status, headers, extra: [("Content-Length", "\(body.count)"), ("Connection", "close")])
        Net.sendAll(fd, Array(h.utf8) + (isHead ? [] : body))
    }

    public func json(_ status: Int, _ value: JSONValue) {
        send(status, [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")], Array(value.jsonString().utf8))
    }

    /// Starts a streamed (chunked) answer; then `write` pieces until the client goes away.
    public func startStream(_ status: Int, _ headers: [(String, String)]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished || streaming { return false }
        streaming = true
        var tv = timeval(tv_sec: 5, tv_usec: 0)   // a client that stops reading must not block everyone else
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return Net.sendAll(fd, Array(head(status, headers, extra: [("Transfer-Encoding", "chunked")]).utf8))
    }

    /// One piece of a streamed answer. false when the client has gone.
    @discardableResult
    public func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        lock.lock(); defer { lock.unlock() }
        if !streaming || finished || bytes.isEmpty { return !finished }
        let ok = Net.sendAll(fd, Array("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + [13, 10])
        if !ok { finished = true }
        return ok
    }
}

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = (HTTPRequest, HTTPResponse) -> Void
    /// Largest request body that is kept (bigger ones are read and dropped, and flagged).
    public let maxBody: Int
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    public private(set) var port = 0

    public init(maxBody: Int, handler: @escaping Handler) {
        self.maxBody = maxBody
        self.handler = handler
    }

    /// Listens on 127.0.0.1:port (0 = any free port). Throws EADDRINUSE etc. as StoreError.io.
    public func start(port wanted: Int) throws {
        signal(SIGPIPE, SIG_IGN)
        let (fd, p) = try Net.listenLoopback(port: wanted)
        lock.lock(); listener = fd; port = p; lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    lock.lock(); let done = stopped; lock.unlock()
                    if done { return }
                    continue
                }
                Thread.detachNewThread { [self] in
                    serve(client)
                    _ = close(client)
                }
            }
        }
    }

    public func stop() {
        lock.lock(); stopped = true; let l = listener; listener = -1; lock.unlock()
        if l >= 0 { _ = shutdown(l, Int32(SHUT_RDWR)); _ = close(l) }
    }

    private func serve(_ fd: Int32) {
        var buf: [UInt8] = []
        var headEnd: Int?
        while headEnd == nil {
            guard let chunk = Net.receive(fd) else { return }
            buf += chunk
            headEnd = Net.find([13, 10, 13, 10], in: buf)
            if (headEnd ?? buf.count) > EgressGuard.maxHeadBytes {
                Net.sendAll(fd, Array("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n".utf8))
                return
            }
        }
        let lines = String(decoding: buf[..<headEnd!], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }),
              parts[1].hasPrefix("/"), Net.isHTTPVersion(parts[2]) else {
            Net.sendAll(fd, Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let old = headers[name] { headers[name] = old + (name == "cookie" ? "; " : ", ") + value } else { headers[name] = value }
        }

        // the body
        var rest = Array(buf[(headEnd! + 4)...])
        var body: [UInt8] = []
        var tooLarge = false
        func keep(_ bytes: ArraySlice<UInt8>) {
            if tooLarge { return }
            if body.count + bytes.count > maxBody { tooLarge = true; body = [] } else { body += bytes }
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            // size line, data, CRLF ... a 0 size ends it (trailers are skipped)
            while true {
                while Net.find([13, 10], in: rest) == nil {
                    guard let more = Net.receive(fd) else { return }
                    rest += more
                }
                let nl = Net.find([13, 10], in: rest)!
                let sizeText = String(decoding: rest[..<nl], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return }
                rest.removeFirst(nl + 2)
                if size == 0 { break }
                while rest.count < size + 2 {
                    guard let more = Net.receive(fd) else { return }
                    rest += more
                }
                keep(rest[..<size])
                rest.removeFirst(size + 2)
            }
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                Net.sendAll(fd, Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            var remaining = length
            let first = rest.prefix(remaining)
            keep(first[...])
            remaining -= first.count
            while remaining > 0 {
                guard let more = Net.receive(fd) else { return }
                let piece = more.prefix(remaining)
                keep(piece[...])
                remaining -= piece.count
            }
        }

        let request = HTTPRequest(method: parts[0], target: parts[1], headers: headers, body: body, bodyTooLarge: tooLarge)
        let response = HTTPResponse(fd: fd, isHead: parts[0] == "HEAD")
        handler(request, response)
    }
}

extension Net {
    /// A listening socket on 127.0.0.1:port (0 = any free port) and the port it got.
    static func listenLoopback(port: Int) throws -> (Int32, Int) {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw StoreError.io(path: "127.0.0.1", operation: "socket", code: errno) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 128) == 0 else {
            let e = errno; _ = close(fd)
            throw StoreError.io(path: "127.0.0.1:\(port)", operation: "listen", code: e)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }
}
