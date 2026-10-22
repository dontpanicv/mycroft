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

    /// The machine `name` means: its exact name in any case, the same letters and digits ("bender 2" for bender-2), or
    /// the start of only one machine's name ("Bender"). The model needn't look names up first.
    func named(_ name: String) -> Machine? {
        if let exact = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let wanted = Self.key(name)
        guard !wanted.isEmpty else { return nil }
        if let same = items.first(where: { Self.key($0.name) == wanted }) { return same }
        let starting = items.filter { Self.key($0.name).hasPrefix(wanted) }
        return starting.count == 1 ? starting[0] : nil
    }

    /// A name's letters and digits, lowercased.
    private static func key(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

nonisolated enum Machines {
    /// Session-scoped, next to the thread list, so tools read the same paired machines the UI shows.
    static let document = Document("mycroft.machines", scope: .session, initial: MachineList())
}

/// The phone's own Ed25519 key, used to sign in to paired machines. It never leaves the keychain.
nonisolated enum PhoneIdentity {
    private static let account = "hands.ed25519"

    /// The phone's identity. Paired machines know only this key, so it must never change by accident: a new key is
    /// made only when the keychain says there is none, never when it merely fails to answer, and never overwrites.
    static func key() throws -> Curve25519.Signing.PrivateKey {
        switch Keychain.lookup(account) {
        case .found(let stored):
            guard let raw = Data(base64Encoded: stored) else { throw KeychainError(status: errSecDecode) }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        case .failed(let status):
            throw KeychainError(status: status)
        case .notFound:
            let key = Curve25519.Signing.PrivateKey()
            if try Keychain.addIfMissing(key.rawRepresentation.base64EncodedString(), for: account) { return key }
            return try Self.key()  // another caller created it first
        }
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
