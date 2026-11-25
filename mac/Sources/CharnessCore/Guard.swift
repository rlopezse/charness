// The egress guard (ported from lib/guard.mjs, the retired Node version). A tiny local HTTPS CONNECT proxy that only tunnels to hosts
// you allow. Claude Code is started with HTTPS_PROXY pointing here, so every host it tries to reach is logged,
// and anything not on the allow-list is refused. It never sees request contents (TLS passes straight through),
// only "host:port".
//
// Built on plain POSIX sockets (not Network.framework) so it compiles and is tested on Linux too:
// `swift run core-checks` sends it the requests in mac/Fixtures/guard.json and requires the answers and log
// entries the Node guard gave (recorded before it was retired).
//
// Honest limit (same as the Node version): proxy variables are advisory. For hard enforcement, also run the
// whole thing in a container/VM or behind a firewall.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One connection attempt, as shown in the Network panel.
public struct GuardLogEntry: Equatable {
    public let ts: Double          // ms since 1970
    public let host: String
    public let port: Double        // a number, as in the Node log (it can be out of range in a bad request)
    public let allowed: Bool
    public let note: String?

    public var json: JSONValue {
        var o: JSONObject = ["ts": .number(ts), "host": .string(host), "port": .number(port), "allowed": .bool(allowed)]
        if let n = note { o["note"] = .string(n) }
        return .object(o)
    }
}

public final class EgressGuard: @unchecked Sendable {
    /// The port it listens on (127.0.0.1 only), once started.
    public private(set) var port: Int = 0

    private let allowList: () -> [String]
    private let upstream: URLComponents?
    private let onLog: (GuardLogEntry) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var live = Set<Int32>()   // sockets in use, closed by stop()
    private var stopped = false

    static let maxHeadBytes = 16 * 1024   // Node's default limit for a request's headers

    /// - allowList: read on every connection ("host", "host:port", "*.domain"; the port defaults to 443)
    /// - upstream: the user's own proxy to chain through (e.g. HTTPS_PROXY at startup), or nil
    public init(allowList: @escaping () -> [String], upstream: String? = nil, onLog: @escaping (GuardLogEntry) -> Void = { _ in }) {
        self.allowList = allowList
        self.upstream = upstream.flatMap { URLComponents(string: $0) }
        self.onLog = onLog
    }

    /// Starts listening on 127.0.0.1 at a free port, and returns that port.
    @discardableResult
    public func start() throws -> Int {
        signal(SIGPIPE, SIG_IGN)   // a write to a socket the other side closed must be an error, not kill us
        let (fd, p) = try Net.listenLoopback(port: 0)
        lock.lock(); listener = fd; port = p; lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        return p
    }

    /// Stops listening and closes every open tunnel.
    public func stop() {
        lock.lock()
        stopped = true
        let all = live
        let l = listener
        listener = -1
        lock.unlock()
        if l >= 0 { _ = shutdown(l, Int32(SHUT_RDWR)); _ = close(l) }
        for fd in all { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    }

    /// Whether `host:port` matches the allow-list. Same rules as the Node guard: case-insensitive; an entry's
    /// trailing ":digits" is its port (443 if there is none); "*.example.com" matches subdomains, not the apex.
    public static func isAllowed(host: String, port: Double, allow: [String]) -> Bool {
        let h = host.lowercased()
        return allow.contains { raw in
            let entry = raw.lowercased()
            var pattern = entry
            var p: Double = 443
            if let colon = entry.lastIndex(of: ":") {
                let digits = entry[entry.index(after: colon)...]
                if !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                    pattern = String(entry[..<colon])
                    p = Double(digits) ?? .nan
                }
            }
            if p != port { return false }
            return pattern == h || (pattern.hasPrefix("*.") && h.hasSuffix(String(pattern.dropFirst())))
        }
    }

    // MARK: connections

    private func track(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        live.insert(fd)
        return true
    }
    private func release(_ fd: Int32) {
        lock.lock(); live.remove(fd); lock.unlock()
        _ = close(fd)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                continue
            }
            guard track(client) else { _ = close(client); return }
            Thread.detachNewThread { [self] in
                serve(client)
                release(client)
            }
        }
    }

    private func reply(_ fd: Int32, _ text: String) { Net.sendAll(fd, Array(text.utf8)) }

    private func serve(_ client: Int32) {
        // the request head: everything up to the blank line
        var buf: [UInt8] = []
        var headEnd: Int?
        while headEnd == nil {
            guard let chunk = Net.receive(client) else { return }   // closed before a whole request: nothing to do
            buf += chunk
            headEnd = Net.find([13, 10, 13, 10], in: buf)
            if headEnd == nil && buf.count > EgressGuard.maxHeadBytes {
                return reply(client, "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n")
            }
        }
        if headEnd! > EgressGuard.maxHeadBytes {
            return reply(client, "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n")
        }
        let head = String(decoding: buf[..<headEnd!], as: UTF8.self)
        let leftover = Array(buf[(headEnd! + 4)...])   // bytes the client sent after the request ("head" in Node)
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // what Node's HTTP parser accepts; anything else gets its "400 Bad Request"
        let methods: Set<String> = ["CONNECT", "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE"]
        guard parts.count == 3, methods.contains(parts[0]), !parts[1].isEmpty, Net.isHTTPVersion(parts[2]) else {
            return reply(client, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        }

        guard parts[0] == "CONNECT" else {
            // Plain-HTTP proxying is deliberately unsupported; Claude only needs HTTPS.
            var host = "?"
            if let u = URLComponents(string: parts[1]), u.scheme != nil, let h = u.host { host = h.lowercased() }
            onLog(GuardLogEntry(ts: Net.nowMs(), host: host, port: 80, allowed: false, note: "plain http"))
            let body = "blocked by charness egress guard\n"
            return reply(client, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        }

        // CONNECT host:port, with a plain host name or address
        guard let (host, port) = Net.splitTarget(parts[1]) else { return }   // just close, as the Node guard does
        let ok = EgressGuard.isAllowed(host: host, port: port, allow: allowList())
        onLog(GuardLogEntry(ts: Net.nowMs(), host: host, port: port, allowed: ok, note: nil))
        guard ok else { return reply(client, "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n") }

        var fromUpstream: [UInt8] = []
        let up: Int32
        if let proxy = upstream {
            guard let (fd, extra) = viaProxy(proxy, host: host, port: port, client: client) else { return }
            up = fd
            fromUpstream = extra
        } else {
            guard port >= 1 && port <= 65535, let fd = Net.connect(host: host, port: Int(port)) else { return }
            up = fd
        }
        guard track(up) else { _ = close(up); return }
        defer { release(up) }

        reply(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
        if !fromUpstream.isEmpty { Net.sendAll(client, fromUpstream) }
        if !leftover.isEmpty { Net.sendAll(up, leftover) }
        Net.pump(client, up)
    }

    /// Chains through the user's own (e.g. corporate) proxy. Returns the tunnel and any bytes that followed the
    /// proxy's answer; nil if it failed (the client has then been answered or the connection just ends).
    private func viaProxy(_ proxy: URLComponents, host: String, port: Double, client: Int32) -> (Int32, [UInt8])? {
        guard let proxyHost = proxy.host, let fd = Net.connect(host: proxyHost, port: proxy.port ?? 80) else { return nil }
        let target = "\(host):\(JSONValue.jsNumber(port))"
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let user = proxy.percentEncodedUser, !user.isEmpty {
            let name = user.removingPercentEncoding ?? user
            let pass = proxy.percentEncodedPassword.map { $0.removingPercentEncoding ?? $0 } ?? ""
            request += "Proxy-Authorization: Basic \(Data("\(name):\(pass)".utf8).base64EncodedString())\r\n"
        }
        Net.sendAll(fd, Array((request + "\r\n").utf8))
        var buf: [UInt8] = []
        while true {
            guard let chunk = Net.receive(fd) else { _ = close(fd); return nil }
            buf += chunk
            if let end = Net.find([13, 10, 13, 10], in: buf) {
                let status = String(decoding: buf[..<end], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
                guard status.count > 1, status[1] == "200" else {
                    reply(client, "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                    _ = close(fd)
                    return nil
                }
                return (fd, Array(buf[(end + 4)...]))
            }
            if buf.count > 64 * 1024 { _ = close(fd); return nil }
        }
    }
}

// MARK: - sockets

/// Small blocking-socket helpers (the guard's, also used by the checks to send raw requests).
public enum Net {
    static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    static func isHTTPVersion(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count == 8 && s.hasPrefix("HTTP/") && (0x30...0x39).contains(u[5]) && u[6] == 0x2E && (0x30...0x39).contains(u[7])
    }

    /// "host:port" as the Node guard reads it: /^([^:]+):(\d+)$/ and a host of letters, digits, . _ -
    static func splitTarget(_ t: String) -> (String, Double)? {
        guard let colon = t.firstIndex(of: ":"), colon != t.startIndex else { return nil }
        let host = String(t[..<colon]), digits = t[t.index(after: colon)...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let port = Double(digits) else { return nil }
        let okHost = host.utf8.allSatisfy { c in
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x5F || c == 0x2D
        }
        return okHost ? (host, port) : nil
    }

    /// A connected TCP socket to host:port (each address the name resolves to is tried in turn), or nil.
    public static func connect(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                if cConnect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
                _ = close(fd)
            }
            ai = a.pointee.ai_next
        }
        return nil
    }

    /// The next bytes from the socket; nil when it is closed (or failed).
    public static func receive(_ fd: Int32) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { return Array(buf[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    @discardableResult
    public static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, $0.count - offset, Int32(sendFlags)) }
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }

    /// Makes receive() give up (return nil) after `seconds` without data.
    public static func setReceiveTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    #if canImport(Darwin)
    static let sendFlags = 0
    #else
    static let sendFlags = Int(MSG_NOSIGNAL)
    #endif

    /// Copies bytes both ways until either side closes, then shuts both down (Node: pipe both ways, and when
    /// either socket closes, destroy the other).
    static func pump(_ a: Int32, _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            copy(from: b, to: a)
            _ = shutdown(a, Int32(SHUT_RDWR)); _ = shutdown(b, Int32(SHUT_RDWR))
            done.signal()
        }
        copy(from: a, to: b)
        _ = shutdown(a, Int32(SHUT_RDWR)); _ = shutdown(b, Int32(SHUT_RDWR))
        done.wait()
    }

    private static func copy(from: Int32, to: Int32) {
        while let chunk = receive(from) { if !sendAll(to, chunk) { return } }
    }
}

// `connect` is also the name of Net.connect(host:port:) above, so call the C function through this.
#if canImport(Darwin)
private let cConnect: (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32 = Darwin.connect
#else
private let cConnect: (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32 = Glibc.connect
#endif
