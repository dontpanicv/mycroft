import CryptoKit
import Foundation
import PiDurableKit
import UIKit

/// A computer running `hands`, paired with this phone (hands/docs/pairing.md).
nonisolated struct Machine: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var hostname: String?
    /// Addresses to try, best first: the pairing request's source, then what the machine reported.
    var addresses: [String]
    var port: Int
    /// SHA-256 of the listener's certificate, hex. Connections to any other certificate are refused.
    var certSha256: String
    var os: String
    var arch: String
    var version: String
    var pairedAt: Date

    var id: String { name }

    var displayOS: String {
        switch os {
        case "macos": "macOS"
        case "linux": "Linux"
        default: os
        }
    }

    /// Hosts to try in order.
    var hosts: [String] {
        var seen = Set<String>()
        return ([hostname].compactMap { $0 } + addresses).filter { seen.insert($0).inserted }
    }
}

nonisolated struct MachineList: Codable, Sendable, Hashable {
    var items: [Machine] = []

    func named(_ name: String) -> Machine? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

nonisolated enum Machines {
    /// Session-scoped, next to the thread list, so tools read the same paired machines the UI shows.
    static let document = Document("mycroft.machines", scope: .session, initial: MachineList())
}

/// The phone's own Ed25519 key, used to sign in to paired machines. It never leaves the keychain.
nonisolated enum PhoneIdentity {
    private static let account = "hands.ed25519"

    static func key() throws -> Curve25519.Signing.PrivateKey {
        if let stored = Keychain.read(account), let raw = Data(base64Encoded: stored) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        try Keychain.write(key.rawRepresentation.base64EncodedString(), for: account)
        return key
    }

    static func publicKeyBase64() throws -> String {
        try key().publicKey.rawRepresentation.base64EncodedString()
    }

    /// `mycroft-auth:<certSha256 hex>:<nonce base64>`, signed — the listener's handshake.
    static func authSignature(certSha256: String, nonce: String, key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: Data(authMessage(certSha256: certSha256, nonce: nonce).utf8)).base64EncodedString()
    }

    static func authMessage(certSha256: String, nonce: String) -> String {
        "mycroft-auth:\(certSha256):\(nonce)"
    }

    @MainActor static var deviceName: String { UIDevice.current.name }
}

extension Data {
    nonisolated var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
