import Foundation
import Testing

@testable import Mycroft

@Suite("hands protocol")
struct HandsProtocolTests {
    @Test func frameRoundTrips() throws {
        let frame = HandsProtocol.Frame(type: .request, id: 7, json: ["op": "hello", "protocol": 1], payload: Data([1, 2, 3]))
        var reader = HandsProtocol.Reader(synced: true)
        let decoded = try reader.feed(try frame.encoded())
        #expect(decoded.count == 1)
        #expect(decoded[0].type == .request)
        #expect(decoded[0].id == 7)
        #expect(decoded[0].json["op"] as? String == "hello")
        #expect(decoded[0].payload == Data([1, 2, 3]))
    }

    @Test func encodesTheDocumentedLayout() throws {
        // u32 length · u8 type · u32 id · u32 jsonLength · json · payload, big-endian.
        let data = try HandsProtocol.Frame(type: .ping, id: 0).encoded()
        #expect(Array(data) == [0, 0, 0, 11, 6, 0, 0, 0, 0, 0, 0, 0, 2, 0x7B, 0x7D])
    }

    @Test func skipsShellNoiseBeforeTheSyncLine() throws {
        var reader = HandsProtocol.Reader(token: "abc")
        let frame = try HandsProtocol.Frame(type: .result, id: 1, json: ["ok": true]).encoded()
        #expect(try reader.feed(Data("Last login: Sun\nPI-EN".utf8)).isEmpty)
        let frames = try reader.feed(Data("V abc\n".utf8) + frame.prefix(5))
        #expect(frames.isEmpty)
        let rest = try reader.feed(frame.dropFirst(5))
        #expect(rest.count == 1 && rest[0].id == 1)
    }

    @Test func rejectsOversizedFrames() {
        var reader = HandsProtocol.Reader(synced: true)
        #expect(throws: HandsProtocol.ProtocolError.self) { try reader.feed(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
    }

    @Test func parsesHTTPRequests() {
        let get = HTTPRequest(parsing: Data("GET /k7m29qxa HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(get?.method == "GET" && get?.path == "/k7m29qxa")
        let partial = HTTPRequest(parsing: Data("POST /k7m29qxa/pair HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":".utf8))
        #expect(partial == nil)
        let post = HTTPRequest(parsing: Data("POST /k7m29qxa/pair HTTP/1.1\r\ncontent-length: 7\r\n\r\n{\"a\":1}".utf8))
        #expect(post?.body == Data("{\"a\":1}".utf8))
    }

    @Test func authMessageMatchesTheSpec() {
        #expect(PhoneIdentity.authMessage(certSha256: "ab", nonce: "bm9uY2U=") == "mycroft-auth:ab:bm9uY2U=")
    }
}
