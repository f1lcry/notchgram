// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import Darwin
import Foundation
import os

/// The agent-facing control channel (D18): HTTP/1.1 over a **Unix domain
/// socket**.
///
/// HTTP because the harness has to read status back *synchronously from one
/// shell command* — a URL scheme is fire-and-forget and
/// `DistributedNotificationCenter` has no reply primitive.
///
/// A Unix socket rather than loopback TCP, which is what this started as.
/// Measured: with an `NWListener`, the Debug build answered but the Developer ID
/// **Release** build in `/Applications` did not — `curl` completed the TCP
/// handshake and sent the request, then timed out with zero bytes back while
/// `lsof` showed the socket in LISTEN. macOS 15+ gates local-network access per
/// application, and a background agent that nobody is at the keyboard to approve
/// simply never receives the connection. That is fatal for this project
/// specifically: M8's launch-at-login item and M10's real-account probe can only
/// be exercised against the `/Applications` copy, which is precisely the Release
/// build.
///
/// A Unix socket is not networking at all. No firewall, no Local Network
/// prompt, no entitlement, and the filesystem permissions are the access
/// control. `curl --unix-socket` speaks to it with no other changes.
///
/// Everything runs on the main queue. Traffic is a handful of requests per
/// milestone, and every command touches panels anyway; a bridge that stops
/// answering because the main thread is wedged is itself a useful signal.
@MainActor
final class DebugServer {
    /// `defaults write com.f1lcry.notchgram DebugBridgeEnabled -bool YES`
    static let defaultsKey = "DebugBridgeEnabled"
    /// `NOTCHGRAM_DEBUG_BRIDGE=1`
    static let environmentKey = "NOTCHGRAM_DEBUG_BRIDGE"

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment[environmentKey] == "1" { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchGram")
    }

    /// Where the harness finds the bridge. Its absence — or a refused
    /// connection — is how a script tells "app not running" from "app wedged".
    ///
    /// `sun_path` is 104 bytes, so this must stay short; it comfortably is.
    static var socketURL: URL {
        supportDirectory.appendingPathComponent("debug.sock")
    }

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "DebugBridge")
    private let router: DebugRouter
    /// A dedicated thread that does nothing but block in `accept`.
    ///
    /// This started as a `DispatchSource` read source on the listening socket
    /// and stopped delivering connections after a while: `connect` still
    /// succeeded (the kernel backlog accepts it) but the handler never fired
    /// again, and the app looked wedged while its main thread sat idle in
    /// `nextEventMatchingMask`. A blocking accept on its own thread has no
    /// arming semantics to get wrong.
    private let acceptQueue = DispatchQueue(label: "com.f1lcry.notchgram.debug-accept")
    private var listenerFD: Int32 = -1

    init(router: DebugRouter) {
        self.router = router
    }

    func start() {
        guard listenerFD < 0 else { return }
        // Writing to a socket the peer already closed raises SIGPIPE, whose
        // default action is to kill the process. A timed-out `curl` is exactly
        // that case, so this must be off before the first response.
        signal(SIGPIPE, SIG_IGN)

        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A socket file left behind by a crash makes `bind` fail with
        // EADDRINUSE forever; there is nothing to preserve in it.
        try? FileManager.default.removeItem(at: url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("DebugBridge socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        let pathBytes = Array(url.path.utf8CString)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // `sun_path` is 104 bytes and imported as a fixed-size tuple. Copying
        // through a separate byte array keeps the exclusive access to `address`
        // to a single scope.
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            log.error("DebugBridge socket path too long: \(url.path, privacy: .public)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                guard let to = destination.baseAddress, let from = source.baseAddress else { return }
                memcpy(to, from, min(source.count, destination.count))
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            log.error("DebugBridge bind/listen failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }
        // Owner-only: the filesystem is the access control.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        listenerFD = fd
        acceptQueue.async { [weak self] in Self.acceptLoop(fd, server: self) }
        log.notice("DebugBridge listening on \(url.path, privacy: .public)")
    }

    func stop() {
        if listenerFD >= 0 {
            // Closing the listener is what unblocks the accept thread.
            close(listenerFD)
            listenerFD = -1
        }
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    /// Blocks until the listening socket is closed.
    private nonisolated static func acceptLoop(_ listenFD: Int32, server: DebugServer?) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Task { @MainActor in
                guard let server else { close(client); return }
                await server.serve(client)
            }
        }
    }

    /// One request, one response, one close.
    ///
    /// Reads are non-blocking and awaited between attempts, so a half-sent
    /// request parks this task rather than the main thread — and the request is
    /// abandoned after five seconds rather than held forever.
    private func serve(_ fd: Int32) async {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var buffer = Data()
        var request: HTTPRequest?
        let deadline = ContinuousClock.now + .seconds(5)

        while ContinuousClock.now < deadline {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                // Returns nil while the request is still incomplete — that is
                // the loop's continuation condition, not an error.
                if let parsed = HTTPRequest(buffer) { request = parsed; break }
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EINTR {
                try? await Task.sleep(for: .milliseconds(4))
                continue
            }
            break
        }

        guard let request else { return }
        let (status, body) = await router.route(request)

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        await write(payload, to: fd)
    }

    /// A short write is normal on a non-blocking socket once the payload passes
    /// the send buffer, which the status JSON with several panels comfortably
    /// does.
    private func write(_ payload: Data, to fd: Int32) async {
        var offset = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while offset < payload.count, ContinuousClock.now < deadline {
            let written: Int = payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else if errno == EAGAIN || errno == EINTR {
                try? await Task.sleep(for: .milliseconds(4))
            } else {
                return
            }
        }
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

/// A parsed HTTP/1.1 request. Returns nil while the buffer is still short of a
/// complete request, which is the read loop's continuation condition.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let body: Data

    init?(_ buffer: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: separator) else { return nil }
        guard let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound],
                                      encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        self.method = String(requestLine[0])
        // Strip any query string; the bridge takes arguments in the JSON body.
        self.path = String(requestLine[1].split(separator: "?", maxSplits: 1)[0])
        self.body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)]
    }
}

#endif
