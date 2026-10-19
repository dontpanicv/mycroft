import Foundation
import UniformTypeIdentifiers
import WebKit
import os

/// Serves Mycroft's screen to its web views from the generations on disk:
///
/// ```
/// mycroft-ui://app/g/<n>/<path>    Documents/agent/generations/<n>/ui/<path> (or generation 0's, see GenerationStore)
/// mycroft-ui://app/draft/<path>    Documents/agent/draft/ui/<path>, for checking a draft before it goes live
/// mycroft-ui://app/lib/<file>      the app's fixed web runtime: preact.js (Preact + hooks + htm) and the fonts
/// ```
///
/// Every generation lives on the same origin, so a page can import the next generation's modules in place.
final class UISchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mycroft-ui"

    let root: URL
    let bundled: URL?
    /// A file that is missing or failed to load, for the page's error report.
    var onMissing: ((String) -> Void)?
    private let log = Logger(subsystem: "dev.mycroft", category: "web")

    init(root: URL, bundled: URL?) {
        self.root = root
        self.bundled = bundled
    }

    static func url(generation: Int?, path: String = "index.html") -> URL {
        URL(string: "\(scheme)://app/\(generation.map { "g/\($0)" } ?? "draft")/\(path)")!
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = resolve(url) else {
            let path = task.request.url?.path() ?? "?"
            log.error("not found: \(path)")
            onMissing?(path)
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.cannotOpenFile))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.contentType(file.pathExtension),
            "Content-Length": "\(data.count)",
            // Generations never change once written, but the draft does: never cache.
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The file a URL names, never outside the generation's `ui/` folder or the runtime.
    func resolve(_ url: URL) -> URL? {
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts.contains(".."), !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        switch parts[0] {
        case "lib":
            let name = parts[1...].joined(separator: "/")
            if name.hasPrefix("fonts/") { return Bundle.main.url(forResource: String(name.dropFirst(6)), withExtension: nil) }
            return Bundle.main.url(forResource: "web-lib", withExtension: nil)?.appending(path: name)
                .takeIf { FileManager.default.fileExists(atPath: $0.path) }
        case "g":
            guard parts.count >= 3, let generation = Int(parts[1]) else { return nil }
            let folder = GenerationStore.folder(of: generation, root: root)
            return GenerationStore.locate("ui/" + parts[2...].joined(separator: "/"), in: folder, bundled: bundled)
        case "draft":
            let folder = GenerationStore.folder(of: nil, root: root)
            return GenerationStore.locate("ui/" + parts[1...].joined(separator: "/"), in: folder, bundled: bundled)
        default:
            return nil
        }
    }

    static func contentType(_ ext: String) -> String {
        switch ext {
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "html": "text/html; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "ttf": "font/ttf"
        default: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

extension URL {
    fileprivate func takeIf(_ keep: (URL) -> Bool) -> URL? { keep(self) ? self : nil }
}
