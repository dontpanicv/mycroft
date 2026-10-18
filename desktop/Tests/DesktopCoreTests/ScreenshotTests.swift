import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import DesktopCore

/// `ui.screenshot` through the fake backend. No test captures the real screen.
@Suite struct ScreenshotTests {
    func makeService(_ backend: FakeBackend = FakeBackend()) -> (DesktopService, FakeBackend) {
        (DesktopService(backend: backend, settleDelay: 0, firstObservation: 1), backend)
    }

    func response(_ service: DesktopService, _ text: String) -> NSDictionary { jsonObject(service.handle(line: line(text))) }

    func errorCode(_ object: NSDictionary) -> String? { (object["error"] as? NSDictionary)?["code"] as? String }

    @Test func encodesThePNGAsBase64WithItsSize() throws {
        let (service, backend) = makeService()
        let object = response(service, #"{"id":"s","op":"ui.screenshot"}"#)
        #expect(object["id"] as? String == "s")
        #expect(object["ok"] as? Bool == true)
        #expect(object["width"] as? Int == 1600)
        #expect(object["height"] as? Int == 1000)
        let base64 = try #require(object["png"] as? String)
        let png = try #require(Data(base64Encoded: base64))
        #expect(png == backend.screenshotResult.png)
        #expect(Set(object.allKeys.compactMap { $0 as? String }) == ["id", "ok", "png", "width", "height"])
        #expect(backend.screenshotWidths == [ScreenshotRequest.defaultMaxWidth])
    }

    @Test func passesMaxWidthAndAcceptsTheMainDisplay() {
        let (service, backend) = makeService()
        #expect(response(service, #"{"id":1,"op":"ui.screenshot","display":"main","maxWidth":800}"#)["ok"] as? Bool == true)
        #expect(response(service, #"{"id":2,"op":"ui.screenshot","display":" Main ","maxWidth":8192}"#)["ok"] as? Bool == true)
        #expect(backend.screenshotWidths == [800, 8192])
    }

    @Test func rejectsBadRequestsWithoutCapturing() {
        let (service, backend) = makeService()
        for request in [
            #"{"id":1,"op":"ui.screenshot","display":"external"}"#,
            #"{"id":1,"op":"ui.screenshot","maxWidth":0}"#,
            #"{"id":1,"op":"ui.screenshot","maxWidth":9000}"#,
            #"{"id":1,"op":"ui.screenshot","maxWidth":"wide"}"#,
            #"{"id":1,"op":"ui.screenshot","display":3}"#,
        ] {
            #expect(errorCode(response(service, request)) == "invalid", "\(request)")
        }
        #expect(backend.screenshotWidths.isEmpty)
    }

    @Test func notPermittedWithoutScreenRecording() {
        let backend = FakeBackend()
        backend.canRecordScreen = false
        let (service, _) = makeService(backend)
        let object = response(service, #"{"id":7,"op":"ui.screenshot"}"#)
        #expect(object["ok"] as? Bool == false)
        #expect(errorCode(object) == "not_permitted")
        #expect(((object["error"] as? NSDictionary)?["message"] as? String)?.contains("Screen Recording") == true)
        #expect(backend.screenshotWidths.isEmpty)
    }

    @Test func needsNoAccessibility() {
        let backend = FakeBackend()
        backend.isTrusted = false
        let (service, _) = makeService(backend)
        #expect(response(service, #"{"id":1,"op":"ui.screenshot"}"#)["ok"] as? Bool == true)
        #expect(errorCode(response(service, #"{"id":2,"op":"ui.observe"}"#)) == "not_trusted")
    }

    @Test func backendErrorsKeepTheirCodes() {
        let backend = FakeBackend()
        backend.screenshotError = DesktopError.notPermitted
        let (service, _) = makeService(backend)
        #expect(errorCode(response(service, #"{"id":1,"op":"ui.screenshot"}"#)) == "not_permitted")
        backend.screenshotError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(errorCode(response(service, #"{"id":1,"op":"ui.screenshot"}"#)) == "failed")
    }

    @Test func screenshotDoesNotDisturbTheObservation() {
        let (service, _) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        _ = response(service, #"{"id":2,"op":"ui.screenshot"}"#)
        #expect(service.currentObservation == "o-1")
    }

    @Test func pingReportsScreenRecording() {
        let backend = FakeBackend()
        let (service, _) = makeService(backend)
        #expect(response(service, #"{"id":1,"op":"ping"}"#)["screenRecording"] as? Bool == true)
        backend.canRecordScreen = false
        let ping = response(service, #"{"id":2,"op":"ping"}"#)
        #expect(ping["screenRecording"] as? Bool == false)
        #expect(ping["trusted"] as? Bool == true)
        #expect(ping["version"] as? String == handsDesktopVersion)
    }

    @Test func aLargeScreenshotCrossesTheSocket() throws {
        let backend = FakeBackend()
        // About 3 MB: the response line (4 MB of base64) is far above the 1 MiB request limit.
        let png = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        backend.screenshotResult = Screenshot(png: png, width: 1600, height: 900)
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        let server = SocketServer(path: temporarySocketPath()) { service.handle(line: $0) }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: server.path)
        client.send(#"{"id":1,"op":"ui.screenshot","maxWidth":1600}"# + "\n" + #"{"id":2,"op":"ping"}"# + "\n")
        let shot = jsonObject(try #require(client.readLine()))
        #expect(shot["height"] as? Int == 900)
        let base64 = try #require(shot["png"] as? String)
        #expect(Data(base64Encoded: base64) == png)
        #expect(jsonObject(try #require(client.readLine()))["id"] as? Int == 2)
    }

    // MARK: Capture helpers (no capture)

    @Test func scaledSizeKeepsTheAspectAndNeverUpscales() {
        #expect(ScreenCapture.scaledSize(pixelWidth: 3456, pixelHeight: 2234, maxWidth: 1600) == (1600, 1034))
        #expect(ScreenCapture.scaledSize(pixelWidth: 1440, pixelHeight: 900, maxWidth: 1600) == (1440, 900))
        #expect(ScreenCapture.scaledSize(pixelWidth: 5120, pixelHeight: 2880, maxWidth: 1600) == (1600, 900))
        #expect(ScreenCapture.scaledSize(pixelWidth: 4000, pixelHeight: 1, maxWidth: 10) == (10, 1))
        #expect(ScreenCapture.scaledSize(pixelWidth: 0, pixelHeight: 900, maxWidth: 1600) == (0, 0))
    }

    @Test func encodesAnImageAsPNG() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try #require(context.makeImage())
        let png = try ScreenCapture.encodePNG(image)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((decoded.width, decoded.height) == (4, 3))
    }

    @Test func aDeclinedCaptureIsNotPermitted() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(ScreenCapture.mapped(declined).code == .notPermitted)
        #expect(ScreenCapture.mapped(NSError(domain: SCStreamErrorDomain, code: -3802)).code == .failed)
    }
}
