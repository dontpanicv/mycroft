// Renders the app icon from the design tokens: canvas, dotted grid, a mono "my" and the accent bar.
// Run from ios/: swift scripts/make-icon.swift Mycroft/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Mycroft/Resources/JetBrainsMono.ttf") as CFURL, .process, nil)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(rgb(0x0B, 0x0B, 0x0D))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(CGColor(gray: 1, alpha: 0.10))
for y in stride(from: 32, to: size, by: 64) {
    for x in stride(from: 32, to: size, by: 64) {
        context.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
    }
}

let base = CTFontCreateWithName("JetBrains Mono" as CFString, 440, nil)
let font = CTFontCreateCopyWithSymbolicTraits(base, 440, nil, .traitBold, .traitBold) ?? base
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x9D, 0x93, 0xFF),
    NSAttributedString.Key(kCTKernAttributeName as String): -24,
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "my", attributes: attributes))
let bounds = CTLineGetImageBounds(line, context)
context.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX, y: 470)
CTLineDraw(line, context)

context.setFillColor(rgb(0x51, 0x47, 0xEF))
context.fill(CGRect(x: 212, y: 250, width: 600, height: 30))

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
