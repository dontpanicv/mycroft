import JavaScriptCore
import UIKit
import WebKit

/// Loads a generation's screen in an invisible web view, the way the agent checks (and looks at) its own screen
/// before it goes live: did it load, what did it log, what does it look like.
enum UIPreview {
    nonisolated struct Result: Sendable {
        enum Outcome: Sendable, Equatable { case rendered, failed, unavailable }
        var outcome: Outcome
        var errors: [String] = []
        var warnings: [String] = []
        var image: Data?

        var summary: String {
            var lines: [String] = switch outcome {
            case .rendered: [errors.isEmpty ? "The screen rendered without errors." : "The screen rendered, with errors:"]
            case .failed: ["The screen failed to render:"]
            case .unavailable: ["The screen couldn't be checked: Mycroft isn't in front, so iOS doesn't run web pages for it."]
            }
            lines += errors.map { "- \($0)" }
            if !warnings.isEmpty { lines += ["Warnings:"] + warnings.map { "- \($0)" } }
            return lines.joined(separator: "\n")
        }

        var problem: String? { outcome == .failed || !errors.isEmpty ? summary : nil }
    }

    private final class Collector {
        var errors: [String] = []
        var warnings: [String] = []
        var continuation: CheckedContinuation<Bool, Never>?

        func finish(_ ready: Bool) {
            continuation?.resume(returning: ready)
            continuation = nil
        }
    }

    /// Renders the draft's screen (or the active generation's, without a draft) at `route`, e.g. `#/settings`.
    static func run(route: String? = nil, snapshot: Bool) async -> Result {
        guard UIApplication.shared.applicationState == .active,
            let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return Result(outcome: .unavailable) }

        let store = AppModel.shared.generations
        let generation: Int? = await store.hasDraft ? nil : await store.state.active
        let bridge = WebBridge(preview: true)
        let handler = WebUI.schemeHandler()
        let collector = Collector()
        handler.onMissing = { collector.errors.append("Missing file: \($0)") }
        bridge.onPageEvent = { event in
            switch event {
            case .ready: collector.finish(true)
            case .failed(_, let message):
                collector.errors.append(message)
                collector.finish(false)
            case .log(let level, let message):
                if level == "error" { collector.errors.append(message) } else if level == "warn" { collector.warnings.append(message) }
            case .hot: break
            }
        }

        // Off to the side of the real screen, at its size: web views only lay out and paint inside a window.
        let size = window.bounds.size
        let webView = WKWebView(frame: CGRect(x: -size.width - 40, y: 0, width: size.width, height: size.height),
                                configuration: WebUI.configuration(bridge: bridge, handler: handler))
        WebUI.style(webView)
        webView.isUserInteractionEnabled = false
        bridge.webView = webView
        window.insertSubview(webView, at: 0)
        defer {
            webView.removeFromSuperview()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            bridge.tearDown()
        }

        let route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 } ?? ""
        let url = URL(string: UISchemeHandler.url(generation: generation).absoluteString + "?preview=1" + route)!
        let ready = await withCheckedContinuation { continuation in
            collector.continuation = continuation
            webView.load(URLRequest(url: url))
            Task {
                try? await Task.sleep(for: WebUI.loadTimeout)
                collector.finish(false)
            }
        }
        // Let data arrive and effects run; errors in that time count too.
        if ready { try? await Task.sleep(for: .milliseconds(route.hasPrefix("#/t/") ? 1500 : 700)) }

        var result = Result(outcome: ready ? .rendered : .failed, errors: collector.errors, warnings: collector.warnings)
        // WebKit names no file for a module that doesn't parse; JavaScriptCore does.
        if !ready || !result.errors.isEmpty, generation == nil {
            result.errors += await syntaxErrors(in: store.draftUIChanges().filter { $0.hasSuffix(".js") }, store: store)
        }
        if !ready && result.errors.isEmpty {
            result.errors.append("The page never reported ready (boot.js calls ui.ready after the first render).")
        }
        if snapshot, ready { result.image = await image(of: webView) }
        return result
    }

    /// Parses the draft's changed modules: `ui/screens/voice.js:3: SyntaxError: …`.
    private static func syntaxErrors(in files: [String], store: GenerationStore) async -> [String] {
        var errors: [String] = []
        for file in files {
            guard let source = try? await store.read("ui/" + file), let problem = syntaxError(inModule: source) else { continue }
            errors.append("ui/\(file):\(problem)")
        }
        return errors
    }

    /// JavaScriptCore checks scripts, not modules: blank out import and export syntax (keeping line numbers) first.
    nonisolated static func syntaxError(inModule source: String) -> String? {
        var script = source
        let patterns = [#"(?m)^\s*import\s[\s\S]*?from\s*['"][^'"]+['"];?"#, #"(?m)^\s*import\s*['"][^'"]+['"];?"#,
                        #"(?m)^\s*export\s*\{[^}]*\}(\s*from\s*['"][^'"]+['"])?;?"#]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: script, range: NSRange(script.startIndex..., in: script)).reversed() {
                let range = Range(match.range, in: script)!
                script.replaceSubrange(range, with: String(repeating: "\n", count: script[range].filter(\.isNewline).count))
            }
        }
        script = script.replacingOccurrences(of: #"(?m)^(\s*)export\s+(default\s+)?"#, with: "$1", options: .regularExpression)
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let body = JSStringCreateWithUTF8CString(script)
        defer { JSStringRelease(body) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context, body, nil, 1, &exception), let exception,
            let value = JSValue(jsValueRef: exception, in: JSContext(jsGlobalContextRef: context))
        else { return nil }
        return "\(value.forProperty("line")?.toInt32() ?? 0): \(value.toString() ?? "SyntaxError")"
    }

    /// A JPEG of the page at 1.5× — sharp enough to read, small enough for the model.
    private static func image(of webView: WKWebView) async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        guard let shot = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let image = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
        return image.jpegData(compressionQuality: 0.8)
    }
}
