import Foundation
import ImageIO
import PiDurableKit
import UniformTypeIdentifiers

/// The agent can show, not only write: `show` puts an image or rendered HTML into the thread, between its messages.
///
/// An image is stored on the tool result's `details` (the screen reads it; the model doesn't, so it costs no tokens
/// on later turns), re-encoded as a JPEG small enough for the phone. HTML stays in the call's arguments; the screen
/// renders it in a sandboxed frame with no scripts and nothing loaded from the network.
nonisolated enum ShowTools {
    struct Arguments: Decodable, Sendable {
        var image: String?
        var machine: String?
        var html: String?
        var caption: String?
    }

    /// The longest side of a shown image, in pixels.
    static let maxPixels = 2000
    /// Images larger than this are refused before decoding.
    static let maxBytes = 25 * 1024 * 1024

    static func makeExtension() -> Extension {
        Extension("mycroft.show") {
            PromptSection("show", tag: false, text: """
                You can show the user things in the thread, not only write: the show tool puts an image or rendered \
                HTML between your messages.
                - image: "latest" is the newest image a tool returned in this thread (images tools return reach only \
                you until you show them); a file path with machine is an image file on that machine; an https URL is \
                an image on the web.
                - html: your own HTML and CSS, rendered as wide as the phone screen (about 360 CSS pixels; the screen \
                around it is dark). Use it when a table, a diagram, a layout or styled text explains better than \
                prose. It must be self-contained: inline CSS and inline SVG or data: images, no JavaScript, nothing \
                loaded from the network.
                Show when seeing beats reading; then answer in a few words. Don't describe what you showed at length.
                """)

            Tool(
                "show",
                description: "Show the user an image or rendered HTML in this thread, between your messages. Give either image or html.",
                parameters: .object([
                    "image": .string("\"latest\" (the newest image a tool returned in this thread), a file path (with machine), or an https URL").optional,
                    "machine": .string("The machine an image file is on").optional,
                    "html": .string("Self-contained HTML with its CSS (no JavaScript, no network), rendered about 360 CSS px wide").optional,
                    "caption": .string("One short line shown under it").optional,
                ]),
                replay: .safe
            ) { (args: Arguments, call) -> ToolResult in
                let caption = args.caption.map { JSONValue.string($0) } ?? .null
                if let html = args.html, !html.isEmpty {
                    guard args.image == nil else { throw ToolError("Give either image or html, not both; call show twice.") }
                    return ToolResult(output: [.text("Shown to the user.")], details: .object(["kind": .string("html"), "caption": caption]))
                }
                guard let source = args.image, !source.isEmpty else { throw ToolError("Give image or html.") }
                let picture = try encode(try await load(source, machine: args.machine, call: call))
                return ToolResult(
                    output: [.text("Shown to the user: an image, \(picture.width)×\(picture.height).")],
                    details: .object([
                        "kind": .string("image"), "caption": caption,
                        "width": .number(Double(picture.width)), "height": .number(Double(picture.height)),
                        "image": .object(["type": .string("image"), "mimeType": .string("image/jpeg"),
                                          "data": .string(picture.data.base64EncodedString())]),
                    ]))
            }
        }
    }

    // MARK: Sources

    static func load(_ source: String, machine: String?, call: ToolCallContext) async throws -> Data {
        if source == "latest" { return try await latestImage(call) }
        if let url = URL(string: source), url.scheme == "https" || url.scheme == "http" {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw ToolError("\(source) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            return data
        }
        guard let name = machine else {
            throw ToolError("An image file needs the machine it is on; or use \"latest\" or an https URL.")
        }
        let machine = try await HandsTools.resolve(name, call)
        return try await HandsPool.shared.with(machine) { hands in
            try await HandsTools.readData(try await HandsTools.absolute(source, hands), on: hands, limit: maxBytes)
        }
    }

    /// The newest image in this thread's tool results (or one shown before).
    static func latestImage(_ call: ToolCallContext) async throws -> Data {
        guard let conversation = try await call.harness.conversation(call.conversationId) else { throw ToolError("No thread") }
        for entry in try await conversation.entries(limit: 60).items {
            guard let result = entry.toolResult else { continue }
            for block in result.content.reversed() {
                if case .image(let image) = block, let data = Data(base64Encoded: image.data) { return data }
            }
            if let data = result.details?["image"]?["data"]?.stringValue, let image = Data(base64Encoded: data) { return image }
        }
        throw ToolError("No tool has returned an image in this thread yet.")
    }

    // MARK: Encoding

    struct Picture {
        let data: Data
        let width: Int
        let height: Int
    }

    /// Any image ImageIO reads (PNG, JPEG, HEIC, GIF, WebP, TIFF…), as a JPEG at most `maxPixels` on its longest side
    /// and small enough to reach the screen (it drops images over 600 KB of base64).
    static func encode(_ data: Data) throws -> Picture {
        guard data.count <= maxBytes else { throw ToolError("The image is over \(maxBytes / 1024 / 1024) MB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ToolError("That isn't an image Mycroft can read.")
        }
        for (pixels, quality) in [(maxPixels, 0.82), (maxPixels, 0.6), (1400, 0.6), (1000, 0.55)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            if output.length <= 420_000 { return Picture(data: output as Data, width: image.width, height: image.height) }
        }
        throw ToolError("The image couldn't be made small enough to show.")
    }
}
