import CryptoKit
import Foundation
import Network
import Testing

@testable import Mycroft

@Suite("hands protocol")
struct HandsProtocolTests {
    @Test func frameRoundTrips() throws {
        let frame = HandsProtocol.Frame(type: .request, id: 7, json: ["op": "hello", "protocol": 1], payload: Data([1, 2, 3]))
        var reader = HandsProtocol.Reader()
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

    @Test func rejectsOversizedFrames() {
        var reader = HandsProtocol.Reader()
        #expect(throws: Failure.self) { try reader.feed(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
    }

    @Test func parsesHTTPRequests() {
        let get = HTTPRequest(parsing: Data("GET /k7m29qxa HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(get?.method == "GET" && get?.path == "/k7m29qxa")
        let partial = HTTPRequest(parsing: Data("POST /k7m29qxa/pair HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":".utf8))
        #expect(partial == nil)
        let post = HTTPRequest(parsing: Data("POST /k7m29qxa/pair HTTP/1.1\r\ncontent-length: 7\r\n\r\n{\"a\":1}".utf8))
        #expect(post?.body == Data("{\"a\":1}".utf8))
        #expect(get?.host == "x")
        // A negative length must not reach the body's range (Swift stops the app on a reversed range).
        #expect(HTTPRequest(parsing: Data("POST /k7m29qxa/pair HTTP/1.1\r\nContent-Length: -1\r\n\r\nx".utf8)) == nil)
    }

    @Test func theSetupCodeOpensOnlyTheScriptOverPlainHTTP() {
        var gate = InstallGate(code: "k7m29q")
        #expect(gate.admit(method: "GET", path: "/k7m29q", secure: false, waiting: true) == .script)
        #expect(gate.admit(method: "GET", path: "/k7m29q/hands-darwin-arm64", secure: false, waiting: true) == .refused(404, "use the address and port in the script"))
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: false, waiting: true) == .refused(404, "use the address and port in the script"))
        #expect(gate.admit(method: "GET", path: "/k7m29q/hands-darwin-arm64", secure: true, waiting: true) == .binary("hands-darwin-arm64"))
        #expect(gate.admit(method: "GET", path: "/wrong", secure: true, waiting: true) == .refused(404, nil))
        #expect(gate.admit(method: "GET", path: "/k7m29q", secure: true, waiting: false) == .refused(404, nil))
    }

    @Test func aSetupCodePairsOnce() {
        var gate = InstallGate(code: "k7m29q")
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: true, waiting: true) == .pair)
        // A second request while the first is being stored, and after it was.
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: true, waiting: true) == .refused(410, "this setup command was already used"))
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: true, waiting: false) == .refused(410, "this setup command was already used"))
        // The install that paired may still finish its downloads.
        #expect(gate.admit(method: "GET", path: "/k7m29q/hands-linux-x86_64", secure: true, waiting: false) == .binary("hands-linux-x86_64"))
    }

    @Test func aFailedPairingCanBeRetried() {
        var gate = InstallGate(code: "k7m29q")
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: true, waiting: true) == .pair)
        gate.pairingFailed()
        #expect(gate.admit(method: "POST", path: "/k7m29q/pair", secure: true, waiting: true) == .pair)
    }

    @Test func aSetupCodeExpires() {
        var gate = InstallGate(code: "k7m29q", expiresAt: .now.addingTimeInterval(-1))
        #expect(gate.admit(method: "GET", path: "/k7m29q", secure: false, waiting: true) == .refused(404, nil))
    }

    @Test func tooManyWrongCodesStopTheServer() {
        var gate = InstallGate(code: "k7m29q")
        for _ in 1..<InstallGate.maxMisses {
            #expect(gate.admit(method: "GET", path: "/guess", secure: false, waiting: true) == .refused(404, nil))
        }
        #expect(gate.admit(method: "GET", path: "/guess", secure: false, waiting: true) == .tooManyMisses)
    }

    /// The Host header becomes the script's download address, inside single quotes: only plain hosts get through.
    @Test func takesOnlyPlainHostsFromTheHostHeader() {
        #expect(HTTPRequest.hostname("100.92.235.118:8484") == "100.92.235.118")
        #expect(HTTPRequest.hostname("iphone-v.netbird.selfhosted:8484") == "iphone-v.netbird.selfhosted")
        #expect(HTTPRequest.hostname("[fd7a:115c:a1e0::1]:8484") == "fd7a:115c:a1e0::1")
        #expect(HTTPRequest.hostname("192.168.1.20") == "192.168.1.20")
        #expect(HTTPRequest.hostname("x';rm -rf ~;'") == nil)
        #expect(HTTPRequest.hostname("a b") == nil)
        #expect(HTTPRequest.hostname("") == nil)
    }

    @Test func namesThePhonesNetworks() {
        let found = LocalNetwork.classify([
            ("pdp_ip0", "10.44.1.9", false), ("utun3", "100.101.7.4", false), ("utun3", "fd7a:115c:a1e0::1234", true),
            ("en0", "192.168.1.20", false), ("en0", "fe80::1", true), ("awdl0", "169.254.3.3", false),
            ("utun5", "100.92.235.118", false), ("utun6", "10.8.0.2", false), ("bridge100", "172.20.10.1", false),
            ("ipsec2", "10.1.1.1", false), ("en0", "192.168.1.20", false),
        ])
        #expect(found.map(\.network) == ["Wi-Fi", "Tailscale", "NetBird", "VPN", "Personal Hotspot"])
        #expect(found.map(\.ip) == ["192.168.1.20", "100.101.7.4", "100.92.235.118", "10.8.0.2", "172.20.10.1"])
        #expect(LocalNetwork.isCarrierGrade("100.64.0.1") && LocalNetwork.isCarrierGrade("100.127.255.255"))
        #expect(!LocalNetwork.isCarrierGrade("100.128.0.1") && !LocalNetwork.isCarrierGrade("100.63.0.1"))
    }

    @Test func installCommandsAddressHostsAsURLsDo() {
        #expect(InstallServer.urlHost("100.92.235.118") == "100.92.235.118")
        #expect(InstallServer.urlHost("fd6f::1") == "[fd6f::1]")
        #expect(InstallServer.host(of: .hostPort(host: "::ffff:192.168.1.5", port: 1)) == "192.168.1.5")
        #expect(InstallServer.host(of: .hostPort(host: "fe80::1%en0", port: 1)) == "fe80::1")
    }

    @Test func authMessageMatchesTheSpec() {
        #expect(PhoneIdentity.authMessage(certSha256: "ab", nonce: "bm9uY2U=") == "mycroft-auth:ab:bm9uY2U=")
    }

    /// hands/docs/pairing.md §4: the phone's handshake signature must verify with hands' vectors.
    @Test func handshakeMatchesHandsTestVectors() throws {
        let seed = Data((0..<32).map { index in UInt8(strtoul(String(Array("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")[index * 2...index * 2 + 1]), nil, 16)) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
        let certSha256 = (0..<32).map { String(format: "%02x", $0) }.joined()
        let nonce = Data(0x20...0x3f).base64EncodedString()
        #expect(nonce == "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")
        let message = Data(PhoneIdentity.authMessage(certSha256: certSha256, nonce: nonce).utf8)
        let vector = try #require(Data(base64Encoded: "qKa3C0FH/CS/urmfJt5xfB2h0Tsk4YQrtxDZg6nxzkTrv5ZBl2ILTqyAMZZr3eSg/o1LivawmAeBjzDQsUxPDg=="))
        #expect(key.publicKey.isValidSignature(vector, for: message))
        let ours = try #require(Data(base64Encoded: try PhoneIdentity.authSignature(certSha256: certSha256, nonce: nonce, key: key)))
        #expect(key.publicKey.isValidSignature(ours, for: message))
    }
}
