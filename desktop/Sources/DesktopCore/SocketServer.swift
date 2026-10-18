import Darwin
import Foundation

/// A Unix domain socket server speaking newline-delimited JSON: one request per line, one response line each.
///
/// Many clients may connect at once. Every request from every client runs on one serial queue, so requests are
/// handled one at a time in arrival order, and each client gets its responses in the order it sent its requests.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data

    public let path: String
    /// A request line longer than this is answered with `invalid` and the connection is closed.
    public static let maxLineLength = 1 << 20

    private let handler: Handler
    private let requests = DispatchQueue(label: "hands-desktop.requests")
    private let acceptQueue = DispatchQueue(label: "hands-desktop.accept")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: Client] = [:]
    public var log: (@Sendable (String) -> Void)?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public struct StartError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Binds the socket with mode 0600 and starts accepting. A stale socket file is replaced; a live one is an error.
    public func start() throws(StartError) {
        signal(SIGPIPE, SIG_IGN)
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw StartError(description: "Cannot create \(directory): \(error.localizedDescription)")
            }
        }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw StartError(description: "Socket path is too long (\(path.utf8.count) bytes, limit \(capacity - 1)): \(path)")
        }
        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(description: "socket(): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        // umask keeps the socket private from the moment it exists; chmod makes sure of it.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let bindErrno = errno
        umask(previousMask)
        guard bound == 0 else {
            close(fd)
            throw StartError(description: "bind(\(path)): \(String(cString: strerror(bindErrno)))")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw StartError(description: "listen(): \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        lock.lock()
        listenFD = fd
        acceptSource = source
        lock.unlock()
        source.resume()
    }

    /// Stops accepting, disconnects clients and removes the socket file.
    public func stop() {
        lock.lock()
        let source = acceptSource
        acceptSource = nil
        let wasListening = listenFD >= 0
        listenFD = -1
        let open = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        source?.cancel()
        open.forEach { $0.close() }
        if wasListening { unlink(path) }
    }

    private func removeStaleSocket() throws(StartError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw StartError(description: "\(path) exists and is not a socket; refusing to replace it.")
        }
        if Self.canConnect(path) {
            throw StartError(description: "Another hands-desktop is already serving on \(path).")
        }
        unlink(path)
    }

    static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8.prefix(buffer.count - 1)) + [0])
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptPending() {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { return }
        while true {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            // Accepted sockets inherit O_NONBLOCK on macOS; writes here are blocking, on the client's own queue.
            _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd: clientFD, server: self)
            lock.lock()
            clients[ObjectIdentifier(client)] = client
            lock.unlock()
            client.start()
        }
    }

    fileprivate func received(_ line: Data, from client: Client) {
        requests.async { [handler] in
            let response = handler(line)
            client.send(response)
        }
    }

    fileprivate func closed(_ client: Client) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        lock.unlock()
    }

    fileprivate final class Client: @unchecked Sendable {
        let fd: Int32
        weak var server: SocketServer?
        let queue = DispatchQueue(label: "hands-desktop.client")
        var source: DispatchSourceRead?
        var buffer = Data()
        var isClosed = false

        init(fd: Int32, server: SocketServer) {
            self.fd = fd
            self.server = server
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }

        /// Runs on `queue`.
        private func readAvailable() {
            guard !isClosed else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                if count < 0, errno == EAGAIN || errno == EINTR { return }
                closeOnQueue()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == 0x0D { line = line.dropLast() }
                guard line.contains(where: { ![0x20, 0x09].contains($0) }) else { continue }
                server?.received(Data(line), from: self)
            }
            if buffer.count > SocketServer.maxLineLength {
                buffer.removeAll()
                let error = Wire.failure(id: .null, .invalid("The request line is longer than \(SocketServer.maxLineLength) bytes."))
                writeAll(error + Data([0x0A]))
                closeOnQueue()
            }
        }

        func send(_ response: Data) {
            queue.async { [self] in
                guard !isClosed else { return }
                if !writeAll(response + Data([0x0A])) { closeOnQueue() }
            }
        }

        @discardableResult
        private func writeAll(_ data: Data) -> Bool {
            data.withUnsafeBytes { raw -> Bool in
                guard var pointer = raw.baseAddress else { return true }
                var remaining = raw.count
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
        }

        func close() { queue.async { [self] in closeOnQueue() } }

        private func closeOnQueue() {
            guard !isClosed else { return }
            isClosed = true
            source?.cancel()
            source = nil
            server?.closed(self)
        }
    }
}
