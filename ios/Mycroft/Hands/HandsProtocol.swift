import Foundation

/// The wire protocol `hands` speaks (hands/docs/protocol.md), one frame per WebSocket message.
///
/// Every frame: u32 length (bytes after it) · u8 type · u32 request id · u32 json length · JSON · raw payload.
/// Big-endian.
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

    /// Accumulates bytes and yields whole frames.
    struct Reader {
        private var buffer = Data()

        mutating func feed(_ bytes: Data) throws -> [Frame] {
            buffer.append(bytes)
            var frames: [Frame] = []
            while buffer.count >= 4 {
                let length = Int(buffer.bigEndianUInt32(at: 0))
                guard length >= 9, length <= HandsProtocol.maxFrame else {
                    throw Failure("bad frame length \(length)")
                }
                guard buffer.count >= 4 + length else { break }
                let start = buffer.startIndex
                guard let type = FrameType(rawValue: buffer[start + 4]) else {
                    throw Failure("unknown frame type \(buffer[start + 4])")
                }
                let id = buffer.bigEndianUInt32(at: 5)
                let jsonLength = Int(buffer.bigEndianUInt32(at: 9))
                guard 9 + jsonLength <= length else { throw Failure("bad json length") }
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
