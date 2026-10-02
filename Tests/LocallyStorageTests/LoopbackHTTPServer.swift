import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import LocallyStorage

/// Minimal single-connection-at-a-time HTTP/1.1 server on 127.0.0.1 for
/// transport contract tests. Supports GET with optional Range and HEAD;
/// not a general-purpose server. Loopback only, never bound to a public
/// interface.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
    }

    /// Response plan for one request. `payload` is the full object; a
    /// request with `Range: bytes=N-` receives `206` with the suffix,
    /// anything else receives `200` with the whole payload.
    struct Plan: Sendable {
        var payload: Data
        var extraHeaders: [String: String] = [:]
        /// Artificial delay before the response body completes, so tests can
        /// pause/cancel mid-transfer. 0 = immediate.
        var stallSeconds: Double = 0
        /// When > 0 the connection is closed after this many body bytes
        /// without a terminating chunk — a mid-transfer drop.
        var truncateBodyAfter: Int? = nil
    }

    private let lock = NSLock()
    private var plans: [String: Plan] = [:]
    private var recorded: [RecordedRequest] = []
    private var listenerFD: Int32 = -1
    private var acceptThread: Thread?
    private var stopped = false

    let port: UInt16

    init() throws {
        #if os(Linux)
        // Glibc exposes SOCK_STREAM as an enum; Darwin as a plain Int32.
        listenerFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listenerFD = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listenerFD >= 0 else { throw ErrnoError("socket") }
        var yes: Int32 = 1
        setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        // 127.0.0.1 written into the in_addr field in memory order
        // (little-endian hosts store s_addr as-is, so no .bigEndian swap).
        addr.sin_addr.s_addr = UInt32(0x0100007F)
        let fd = listenerFD
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ErrnoError("bind") }
        guard listen(fd, 16) == 0 else { throw ErrnoError("listen") }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { throw ErrnoError("getsockname") }
        port = UInt16(bigEndian: actual.sin_port)
    }

    func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func setPlan(_ plan: Plan, for path: String) {
        lock.lock(); plans[path] = plan; lock.unlock()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Starts the accept loop on a DEDICATED thread — never on the Swift
    /// Concurrency cooperative pool. A blocking accept() pinned to a
    /// cooperative thread starves the pool (its size ~ CPU count) and can
    /// deadlock later async tests; see run 36958123074 hang forensics.
    /// Idempotent: a second call while running is a no-op.
    func start() {
        lock.lock()
        if acceptThread != nil { lock.unlock(); return }
        stopped = false
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "LoopbackHTTPServer.accept"
        acceptThread = thread
        lock.unlock()
        thread.start()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenerFD
            let isStopped = stopped
            lock.unlock()
            if isStopped || fd < 0 { return }
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                // EBADF/EINVAL after stop() shuts the listener down.
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                // Transient error (e.g. EINTR/ECONNABORTED): keep accepting.
                continue
            }
            // Handle inline on this thread: the server is
            // one-connection-at-a-time by design, and spawning connection
            // work onto the cooperative pool is exactly what we must avoid.
            handle(connection: conn)
        }
    }

    /// Stops the accept loop and joins its thread (bounded wait). On Linux,
    /// close() alone does NOT wake a thread blocked in accept() — only
    /// shutdown(fd, SHUT_RDWR) does — so we shutdown first, then close.
    func stop() {
        lock.lock()
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        let thread = acceptThread
        lock.unlock()
        if fd >= 0 {
            // Glibc exposes SHUT_RDWR as Int; Darwin as Int32.
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        // Bounded join: wait for the accept thread to exit (it returns as
        // soon as accept() unblocks with EBADF/EINVAL), at most 5 s.
        if let thread {
            let deadline = Date().addingTimeInterval(5)
            while !thread.isFinished && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        lock.lock(); acceptThread = nil; lock.unlock()
    }

    deinit {
        stop()
    }

    struct ErrnoError: Error { var what: String; init(_ w: String) { what = w } }

    private func handle(connection fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        buffer.reserveCapacity(16 * 1024)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !buffer.contains(Data("\r\n\r\n".utf8)), buffer.count < 64 * 1024 {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 8192, 0) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        lock.lock()
        recorded.append(RecordedRequest(method: method, path: path, headers: headers))
        let plan = plans[path]
        let stoppedNow = stopped
        lock.unlock()
        guard !stoppedNow, let plan else {
            writeAll(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        if method == "HEAD" {
            var response = "HTTP/1.1 200 OK\r\nContent-Length: \(plan.payload.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            for (k, v) in plan.extraHeaders { response += "\(k): \(v)\r\n" }
            response += "\r\n"
            writeAll(fd, response)
            return
        }
        var body = plan.payload
        var status = "200 OK"
        if let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst("bytes=".count)
            if let dash = spec.firstIndex(of: "-") {
                let startString = spec[..<dash]
                if let start = Int(startString), start > 0, start < plan.payload.count {
                    body = plan.payload.suffix(from: start)
                    status = "206 Partial Content"
                }
            }
        }
        var response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        for (k, v) in plan.extraHeaders { response += "\(k): \(v)\r\n" }
        response += "\r\n"
        writeAll(fd, response)
        if let truncate = plan.truncateBodyAfter, truncate < body.count {
            writeAll(fd, body.prefix(truncate))
            return  // close without the remaining bytes: mid-transfer drop
        }
        if plan.stallSeconds > 0 {
            // Send half, wait, send the rest so pause/cancel lands mid-body.
            let half = body.count / 2
            writeAll(fd, body.prefix(half))
            Thread.sleep(forTimeInterval: plan.stallSeconds)
            writeAll(fd, body.suffix(from: half))
        } else {
            writeAll(fd, body)
        }
    }

    private func writeAll(_ fd: Int32, _ string: String) {
        writeAll(fd, Data(string.utf8))
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
