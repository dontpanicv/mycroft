// `ui.screenshot`: the main display through ScreenCaptureKit, scaled and encoded as PNG. Needs Screen Recording.

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum ScreenCapture {
    /// CGPreflightScreenCaptureAccess(): whether this process (its responsible app) may record the screen. Never prompts.
    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// The output size for a display of `pixelWidth` x `pixelHeight`: its native pixels, scaled down (never up) so the
    /// width is at most `maxWidth`, keeping the aspect ratio.
    public static func scaledSize(pixelWidth: Int, pixelHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard pixelWidth > 0, pixelHeight > 0, maxWidth > 0 else { return (0, 0) }
        guard pixelWidth > maxWidth else { return (pixelWidth, pixelHeight) }
        let height = Int((Double(pixelHeight) * Double(maxWidth) / Double(pixelWidth)).rounded())
        return (maxWidth, max(1, height))
    }

    /// Captures the main display (the one with the menu bar) with the pointer, scaled to at most `maxWidth` pixels.
    /// Blocks the calling thread; call it off the main thread.
    public static func captureMainDisplay(maxWidth: Int, timeout: TimeInterval = 10) throws -> Screenshot {
        let mainID = CGMainDisplayID()
        let content: SCShareableContent = try wait(timeout, "list the displays") { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                done(content.map(Unchecked.init), error)
            }
        }.value
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw DesktopError.failed("There is no display to capture.")
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let size = scaledSize(pixelWidth: mode?.pixelWidth ?? display.width, pixelHeight: mode?.pixelHeight ?? display.height,
                              maxWidth: maxWidth)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        let image: CGImage = try wait(timeout, "capture the screen") { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                done(image.map(Unchecked.init), error)
            }
        }.value
        return Screenshot(png: try encodePNG(image), width: image.width, height: image.height)
    }

    public static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw DesktopError.failed("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DesktopError.failed("Could not encode the screenshot as PNG.") }
        return data as Data
    }

    /// A ScreenCaptureKit error as the protocol reports it: a refusal is `not_permitted`.
    static func mapped(_ error: Error) -> DesktopError {
        if let error = error as? DesktopError { return error }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .notPermitted
        }
        return .failed("Screen capture failed: \(nsError.localizedDescription)")
    }

    /// Carries a ScreenCaptureKit result from its completion queue to the waiting thread.
    struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Unchecked<Value>?
        var error: Error?
    }

    private static func wait<Value>(_ timeout: TimeInterval, _ what: String,
                                    _ start: (@escaping @Sendable (Unchecked<Value>?, Error?) -> Void) -> Void) throws -> Unchecked<Value> {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        start { value, error in
            box.value = value
            box.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw DesktopError.failed("Timed out after \(Int(timeout)) s trying to \(what).")
        }
        if let error = box.error { throw mapped(error) }
        guard let value = box.value else { throw DesktopError.failed("Could not \(what).") }
        return value
    }
}
