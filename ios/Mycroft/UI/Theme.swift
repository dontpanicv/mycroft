import SwiftUI

/// Design tokens: grep.ai's console for content, Liquid Glass for controls. See docs/DESIGN.md.
enum Theme {
    static let canvas = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255)
    static let raised = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x18 / 255)
    static let ink = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF5 / 255)
    static let inkMuted = Color(red: 0xAA / 255, green: 0xAA / 255, blue: 0xB4 / 255)
    static let inkFaint = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.11)
    static let accent = Color(red: 0x51 / 255, green: 0x47 / 255, blue: 0xEF / 255)
    static let accentSoft = Color(red: 0x9D / 255, green: 0x93 / 255, blue: 0xFF / 255)
    static let success = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    static let danger = Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
    static let gutter: CGFloat = 20
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
