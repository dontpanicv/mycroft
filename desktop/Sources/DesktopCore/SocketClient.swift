import Darwin
import Foundation

/// One request to a running helper over its socket, as `hands` sends it. Used by the CLI to ask the LaunchAgent's
/// helper (whose TCC identity is Mycroft Hands) rather than answer for the terminal it was started from.
public enum SocketClient {
    /// Sends one request line and returns the response line, or nil when nothing answers within `timeout`.
    public static func request(path: String, line: Data, timeout: TimeInterval = 2) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let seconds = Int(timeout)
        var interval = timeval(tv_sec: seconds, tv_usec: Int32((timeout - Double(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(line) + [0x0A]
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) { return buffer[buffer.startIndex..<newline] }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// The helper's `ping`, or nil when no helper answers.
    public static func ping(path: String, timeout: TimeInterval = 2) -> PingResult? {
        guard let response = request(path: path, line: Data(#"{"id":1,"op":"ping"}"#.utf8), timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(PingResult.self, from: response)
    }
}
