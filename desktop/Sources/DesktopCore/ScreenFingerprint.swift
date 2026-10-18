import Foundation

/// A cheap signature of what is on screen, taken before and after an action to compute `screenChanged`.
///
/// Ported from jev-use's `Desktop.fingerprint(of:)`: the app, the focused window's title and frame, the focused control,
/// and the window's element structure. A digest of the elements' roles, labels and values is added so a changed value
/// (text typed into a field, a toggled checkbox) counts as a change too.
public struct ScreenFingerprint: Equatable, Sendable, CustomStringConvertible {
    public var pid: Int32
    public var window: String?
    public var windowFrame: String?
    public var focused: String?
    public var elementCount: Int
    public var digest: UInt64

    public init(pid: Int32, window: String?, windowFrame: String?, focused: String?, elementCount: Int, digest: UInt64) {
        self.pid = pid
        self.window = window
        self.windowFrame = windowFrame
        self.focused = focused
        self.elementCount = elementCount
        self.digest = digest
    }

    /// Nothing readable (no app in front, or it has quit).
    public static let empty = ScreenFingerprint(pid: 0, window: nil, windowFrame: nil, focused: nil, elementCount: 0,
                                                digest: Digest.offsetBasis)

    public func differs(from other: ScreenFingerprint) -> Bool { self != other }

    public var description: String {
        "\(pid)|\(window ?? "-")|\(windowFrame ?? "-")|\(focused ?? "-")|\(elementCount)|\(String(digest, radix: 16))"
    }

    /// FNV-1a over the elements in walk order. Deterministic across processes, unlike `Hasher`.
    public struct Digest: Sendable {
        public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        static let prime: UInt64 = 0x0000_0100_0000_01b3
        public private(set) var value: UInt64 = offsetBasis
        public private(set) var count = 0

        public init() {}

        public mutating func add(role: String, label: String, value: String?) {
            count += 1
            feed(role)
            feed(label)
            feed(value ?? "\u{0}")
        }

        private mutating func feed(_ text: String) {
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* Self.prime
            }
            // A field separator, so ("ab", "c") and ("a", "bc") differ.
            value ^= 0x1f
            value = value &* Self.prime
        }
    }
}
