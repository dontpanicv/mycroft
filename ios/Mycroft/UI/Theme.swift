import SwiftUI

/// Design tokens: grep.ai's console for content, Liquid Glass for controls. See docs/DESIGN.md.
///
/// The screen itself is web code (agent/generation-0/ui/style.css); these tokens are for what stays native: the Live
/// Activity and the recovery screen. The colours come from ``Appearance``, which the page keeps in sync with its own.
enum Theme {
    static var canvas: Color { Appearance.shared.color(\.canvas) }
    static var raised: Color { Appearance.shared.color(\.raised) }
    static var ink: Color { Appearance.shared.color(\.ink) }
    static var inkMuted: Color { Appearance.shared.color(\.inkMuted) }
    static let inkFaint = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.11)
    static var accent: Color { Appearance.shared.color(\.accent) }
    static var accentSoft: Color { Appearance.shared.color(\.accentSoft) }
    static var success: Color { Appearance.shared.color(\.success) }
    static var danger: Color { Appearance.shared.color(\.danger) }
    static let gutter: CGFloat = 20
}

/// Mycroft's colours as the web screen last reported them (`ui.theme`).
@Observable
final class Appearance {
    static let shared = Appearance()

    nonisolated struct Values: Codable, Equatable, Sendable {
        var accent: String?
        var accentSoft: String?
        var canvas: String?
        var raised: String?
        var ink: String?
        var inkMuted: String?
        var success: String?
        var danger: String?
    }

    nonisolated static let defaults = Values(
        accent: "#5147EF", accentSoft: "#9D93FF", canvas: "#0B0B0D", raised: "#141418", ink: "#F4F4F5",
        inkMuted: "#AAAAB4", success: "#4ADE80", danger: "#F87171")

    private(set) var values = Appearance.stored ?? Appearance.defaults

    /// Kept between launches, so native parts have the right colours before the page reports them.
    private static let key = "mycroft.appearance"
    private static var stored: Values? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Values.self, from: $0) }
    }

    func apply(_ new: Values) {
        let merged = Values(
            accent: new.accent ?? Self.defaults.accent, accentSoft: new.accentSoft ?? Self.defaults.accentSoft,
            canvas: new.canvas ?? Self.defaults.canvas, raised: new.raised ?? Self.defaults.raised,
            ink: new.ink ?? Self.defaults.ink, inkMuted: new.inkMuted ?? Self.defaults.inkMuted,
            success: new.success ?? Self.defaults.success, danger: new.danger ?? Self.defaults.danger)
        guard merged != values else { return }
        values = merged
        UserDefaults.standard.set(try? JSONEncoder().encode(merged), forKey: Self.key)
    }

    func color(_ key: KeyPath<Values, String?>) -> Color {
        values[keyPath: key].flatMap(Color.init(hex:)) ?? Self.defaults[keyPath: key].flatMap(Color.init(hex:)) ?? .white
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    nonisolated init?(hex: String) {
        guard let (r, g, b, a) = Color.components(hex: hex) else { return nil }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    nonisolated static func components(hex: String) -> (Double, Double, Double, Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let rgba = text.count == 6 ? (value << 8) | 0xFF : value
        return (Double((rgba >> 24) & 0xFF) / 255, Double((rgba >> 16) & 0xFF) / 255, Double((rgba >> 8) & 0xFF) / 255,
                Double(rgba & 0xFF) / 255)
    }
}

extension Font {
    /// JetBrains Mono: headlines, labels, tool calls, numbers.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }

    /// Schibsted Grotesk: prose.
    static func grotesk(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Schibsted Grotesk", size: size).weight(weight)
    }
}

/// An uppercase, tracked mono label — grep.ai's section labels and tags.
struct MonoLabel: View {
    let text: String
    var color: Color = Theme.inkMuted
    var size: CGFloat = 11

    init(_ text: String, color: Color = Theme.inkMuted, size: CGFloat = 11) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(size, weight: .medium))
            .tracking(size * 0.12)
            .foregroundStyle(color)
    }
}

/// A square, hairline-bordered status tag: RUNNING, DONE, PHONE.
struct Tag: View {
    let text: String
    var color: Color = Theme.inkMuted

    var body: some View {
        MonoLabel(text, color: color, size: 9.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.55), lineWidth: 1))
    }
}

/// grep.ai's dotted background grid.
struct DotGrid: View {
    var pitch: CGFloat = 22
    var opacity: Double = 0.07

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.4, height: 1.4))
            var y: CGFloat = pitch / 2
            while y < size.height {
                var x: CGFloat = pitch / 2
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.white.opacity(opacity)))
                    x += pitch
                }
                y += pitch
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A square content card: hairline border, no radius.
    func hairlineCard(padding: CGFloat = 14, fill: Color = .clear) -> some View {
        self.padding(padding)
            .background(fill)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    /// The app canvas behind every screen.
    func canvasBackground(grid: Bool = false) -> some View {
        background {
            ZStack {
                Theme.canvas
                if grid { DotGrid() }
            }
            .ignoresSafeArea()
        }
    }
}
