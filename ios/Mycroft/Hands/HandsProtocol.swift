import Foundation

/// The pi-env wire protocol that `hands serve` speaks (hands/docs/protocol.md).
///
/// Every frame: u32 length (bytes after it) · u8 type · u32 request id · u32 json length · JSON · raw payload.
/// Big-endian. Before the first frame the daemon prints `PI-ENV <token>\n`; anything earlier is shell noise.
nonisolated enum HandsProtocol {
    static let version = 1
    static let maxFrame = 16 * 1024 * 1024

    enum FrameType: UInt8, Sendable {
        case request = 1, result = 2, error = 3, event = 4, cancel = 5, ping = 6
    }

    struct Frame: @unchecked Sendable {
        var type: FrameType
        var id: UInt32
        var json: [String: Any]
        var payload: Data

        init(type: FrameType, id: UInt32, json: [String: Any] = [:], payload: Data = Data()) {
            self.type = type
            self.id = id
            self.json = json
            self.payload = payload
        }

        func encoded() throws -> Data {
            let body = try JSONSerialization.data(withJSONObject: json)
            var data = Data()
            data.appendBigEndian(UInt32(9 + body.count + payload.count))
            data.append(type.rawValue)
            data.appendBigEndian(id)
            data.appendBigEndian(UInt32(body.count))
            data.append(body)
            data.append(payload)
            return data
        }
    }

    struct ProtocolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Accumulates bytes from stdout and yields whole frames, after skipping everything up to the sync line.
    struct Reader {
        private var buffer = Data()
        private var synced = false
        private let syncLine: Data

        /// For stdout of `hands serve` (SSH): skips everything up to the sync line.
        init(token: String) {
            syncLine = Data("PI-ENV \(token)\n".utf8)
        }

        /// For WebSocket messages, which carry whole frames and no sync line.
        init(synced: Bool) {
            syncLine = Data()
            self.synced = synced
        }

        mutating func feed(_ bytes: Data) throws -> [Frame] {
            buffer.append(bytes)
            if !synced {
                guard let range = buffer.range(of: syncLine) else {
                    // Keep only a tail long enough to still contain a split sync line.
                    if buffer.count > 64 * 1024 { buffer = buffer.suffix(syncLine.count) }
                    return []
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                synced = true
            }
            var frames: [Frame] = []
            while buffer.count >= 4 {
                let length = Int(buffer.bigEndianUInt32(at: 0))
                guard length >= 9, length <= HandsProtocol.maxFrame else {
                    throw ProtocolError(message: "bad frame length \(length)")
                }
                guard buffer.count >= 4 + length else { break }
                let start = buffer.startIndex
                guard let type = FrameType(rawValue: buffer[start + 4]) else {
                    throw ProtocolError(message: "unknown frame type \(buffer[start + 4])")
                }
                let id = buffer.bigEndianUInt32(at: 5)
                let jsonLength = Int(buffer.bigEndianUInt32(at: 9))
                guard 9 + jsonLength <= length else { throw ProtocolError(message: "bad json length") }
                let jsonData = buffer.subdata(in: (start + 13)..<(start + 13 + jsonLength))
                let payload = buffer.subdata(in: (start + 13 + jsonLength)..<(start + 4 + length))
                let json = jsonLength == 0 ? [:] : (try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:])
                frames.append(Frame(type: type, id: id, json: json, payload: payload))
                buffer.removeSubrange(start..<(start + 4 + length))
            }
            return frames
        }
    }
}

extension Data {
    nonisolated mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    nonisolated func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
