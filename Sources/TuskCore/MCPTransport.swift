import Foundation

// MARK: - Low-level fd helpers (line-delimited framing, matching MCP stdio)

/// Reads newline-delimited lines from a file descriptor, buffering partial reads.
final class FDLineReader {
    private let fd: Int32
    private var buffer = [UInt8]()

    init(_ fd: Int32) { self.fd = fd }

    /// Next line without its trailing newline, or nil at EOF.
    func next() -> String? {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[0..<idx])
                buffer.removeSubrange(0...idx)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n <= 0 {
                if buffer.isEmpty { return nil }
                let rest = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return rest.isEmpty ? nil : rest
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Write a string plus a trailing newline, handling partial writes.
func writeLine(_ fd: Int32, _ s: String) {
    var bytes = Array(s.utf8)
    bytes.append(0x0A)
    bytes.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

// MARK: - Unix domain socket helpers

private func makeSockaddrUn(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path) // 104 on macOS
    guard path.utf8.count < capacity else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            _ = path.withCString { strcpy(dst, $0) }
        }
    }
    return addr
}

private func bindUnix(_ fd: Int32, _ path: String) -> Bool {
    guard var addr = makeSockaddrUn(path) else { return false }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    } == 0
}

private func connectUnix(_ fd: Int32, _ path: String) -> Bool {
    guard var addr = makeSockaddrUn(path) else { return false }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    } == 0
}

// MARK: - Socket MCP server (the app hosts this)

/// Serves MCP over a unix-domain socket. Each accepted client gets its own
/// `MCPSession`, all sharing the same live `Database` — so an agent sees exactly
/// the connections the GUI has open.
public final class MCPSocketServer: @unchecked Sendable {
    private let db: Database
    private let connection: Connection
    public let socketPath: String

    private var listenFD: Int32 = -1
    private var running = false

    public init(db: Database, connection: Connection, socketPath: String = TuskPaths.mcpSocketPath) {
        self.db = db
        self.connection = connection
        self.socketPath = socketPath
    }

    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(socketPath) // clear any stale socket

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PGError.message("socket() failed (errno \(errno))") }
        guard bindUnix(fd, socketPath) else {
            close(fd)
            throw PGError.message("could not bind unix socket at \(socketPath)")
        }
        chmod(socketPath, 0o600) // owner-only
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw PGError.message("listen() failed (errno \(errno))")
        }
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if running { continue } else { break } }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        let session = MCPSession(db: db, base: connection)
        let reader = FDLineReader(client)
        while let line = reader.next() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // Bridge the async session onto this blocking client thread, preserving order.
            let sem = DispatchSemaphore(value: 0)
            var response: String?
            Task { response = await session.handle(line); sem.signal() }
            sem.wait()
            if let response { writeLine(client, response) }
        }
        close(client)
    }
}

// MARK: - Stdio session (fallback: serve MCP directly over stdin/stdout)

/// Run an MCP session over stdin/stdout. Used when no app socket is available,
/// so `tusk mcp` still works standalone from PG* env vars.
public func runStdioMCPSession(db: Database, connection: Connection) async {
    let session = MCPSession(db: db, base: connection)
    let reader = FDLineReader(0)
    while let line = reader.next() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        if let response = await session.handle(line) { writeLine(1, response) }
    }
}

// MARK: - Stdio ↔ socket bridge (what Claude Code spawns as `tusk mcp`)

/// Connect to the app's MCP socket and relay bytes between it and stdin/stdout.
/// Framing is identical on both sides, so this is a verbatim passthrough.
/// Returns false if the socket can't be reached.
public func runMCPSocketBridge(socketPath: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    guard connectUnix(fd, socketPath) else { close(fd); return false }

    // stdin -> socket, on a separate thread
    let pump = Thread {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(0, &buf, 4096)
            if n <= 0 { shutdown(fd, SHUT_WR); break }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: off), n - off) }
                if w <= 0 { break }
                off += w
            }
        }
    }
    pump.start()

    // socket -> stdout, on this thread
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, 4096)
        if n <= 0 { break }
        var off = 0
        while off < n {
            let w = buf.withUnsafeBytes { write(1, $0.baseAddress!.advanced(by: off), n - off) }
            if w <= 0 { break }
            off += w
        }
    }
    close(fd)
    return true
}
