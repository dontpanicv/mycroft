import Observation
import SwiftUI
import UIKit
import WebKit
import os

/// Mycroft's screen: the active generation's `ui/` in a full-screen web view.
///
/// The screen is the agent's own code, like its behaviour, so it changes the same way: a new generation is shown with
/// ``show(generation:)``, which asks the page to swap in the new modules in place (state lives in Pi Durable and in the
/// page's saved UI state, so nothing is lost). A page that fails to load is rolled back to the last good generation;
/// if even that fails, ``RootView`` shows the native recovery screen.
@Observable
final class WebUI: NSObject {
    static let shared = WebUI()

    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// How a new generation reached the screen.
    nonisolated enum ShowResult: Sendable, Equatable {
        /// On screen now; `changed` are the screen files that changed (empty: only the agent changed).
        case applied(changed: [String])
        /// Mycroft isn't on screen; the generation loads when the user opens it.
        case notVisible
        case failed(String)
    }

    private(set) var status: Status = .loading
    /// The newest errors the page reported, newest last. The agent sees them in self_status.
    private(set) var errors: [String] = []

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var bridge: WebBridge?
    /// The generation whose screen code is running in the page.
    @ObservationIgnored private(set) var pageGeneration: Int?
    @ObservationIgnored private var waiter: (generation: Int, continuation: CheckedContinuation<ShowResult, Never>)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Whether a failed load should roll back by itself (boot) or report to whoever asked for it.
    @ObservationIgnored private var recoverOnFailure = true
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "web")

    static let loadTimeout: Duration = .seconds(12)

    // MARK: The web view

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let bridge = WebBridge(preview: false)
        bridge.onPageEvent = { [weak self] event in self?.handle(event) }
        let handler = Self.schemeHandler()
        handler.onMissing = { [weak self] path in self?.record("error", "Missing file: \(path)") }
        let webView = WKWebView(frame: .zero, configuration: Self.configuration(bridge: bridge, handler: handler))
        Self.style(webView)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        bridge.webView = webView
        self.bridge = bridge
        self.webView = webView
        return webView
    }

    static func schemeHandler() -> UISchemeHandler {
        UISchemeHandler(root: AppModel.shared.generations.root,
                        bundled: Bundle.main.url(forResource: "generation-0", withExtension: nil))
    }

    static func configuration(bridge: WebBridge, handler: UISchemeHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: UISchemeHandler.scheme)
        let content = configuration.userContentController
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: "mycroft")
        content.addUserScript(WKUserScript(source: guardScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.allowsInlineMediaPlayback = true
        configuration.suppressesIncrementalRendering = true
        return configuration
    }

    static func style(_ webView: WKWebView) {
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.canvas)
        webView.scrollView.backgroundColor = UIColor(Theme.canvas)
        // The page lays itself out like an app: it scrolls inside, the page itself never moves.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsLinkPreview = false
        webView.isInspectable = true
        webView.hideInputAccessory()
    }

    /// Runs before any page code, and can't be changed by the agent: reports every error, even when boot.js itself
    /// is broken.
    static let guardScript = """
        (() => {
          const post = (op, args) => { try { window.webkit.messageHandlers.mycroft.postMessage({ op, args }) } catch {} }
          const report = (level, message) => post('ui.log', { level, message: String(message).slice(0, 4000) })
          addEventListener('error', (event) => {
            if (event.target && event.target !== window && (event.target.src || event.target.href)) {
              report('error', 'Failed to load ' + (event.target.src || event.target.href))
              return
            }
            const where = event.filename ? ` (${event.filename.split('/app/').pop()}:${event.lineno}:${event.colno})` : ''
            report('error', (event.error && event.error.stack ? event.error.stack : event.message) + where)
          }, true)
          addEventListener('unhandledrejection', (event) => report('error', 'Unhandled rejection: ' + (event.reason && event.reason.stack || event.reason)))
          for (const level of ['error', 'warn']) {
            const original = console[level]
            console[level] = (...parts) => { report(level, parts.map((part) => part && part.stack ? part.stack : String(part)).join(' ')); original.apply(console, parts) }
          }
        })()
        """

    // MARK: Loading

    /// Loads a generation's screen from scratch. At boot, a screen that fails rolls back to the last good generation.
    func load(generation: Int, recover: Bool = true) {
        let webView = makeWebView()
        status = .loading
        pageGeneration = generation
        recoverOnFailure = recover
        log.info("loading the screen of generation \(generation)")
        webView.load(URLRequest(url: UISchemeHandler.url(generation: generation)))
        startWatchdog(generation)
    }

    private func startWatchdog(_ generation: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled, let self, self.status == .loading else { return }
            // A page can't load while the app is in the background; the clock restarts when the user is back.
            guard UIApplication.shared.applicationState == .active else { return }
            self.pageFailed(generation: generation, message: self.failureSummary("The screen didn't finish loading"))
        }
    }

    func reload() {
        load(generation: pageGeneration ?? AppModel.shared.generation.active)
    }

    /// The app is back in front: give a load that started in the background its full time.
    func appBecameActive() {
        if status == .loading, let pageGeneration { startWatchdog(pageGeneration) }
    }

    /// Puts a generation's screen up. When the page is showing, it swaps the changed modules in place; otherwise
    /// the generation loads from scratch.
    func show(generation: Int) async -> ShowResult {
        let visible = UIApplication.shared.applicationState == .active
        guard status == .ready, let bridge, let from = pageGeneration else {
            load(generation: generation, recover: false)
            return visible ? await wait(for: generation) : .notVisible
        }
        let changed = await AppModel.shared.generations.uiChanges(from: from, to: generation)
        guard !changed.isEmpty else {
            pageGeneration = generation
            return .applied(changed: [])
        }
        guard visible else {
            load(generation: generation, recover: false)
            return .notVisible
        }
        log.info("hot reload \(from) → \(generation): \(changed)")
        bridge.send("hot", ["generation": generation, "changed": changed])
        let result = await wait(for: generation)
        if case .applied = result { return .applied(changed: changed) }
        return result
    }

    private func wait(for generation: Int) async -> ShowResult {
        waiter?.continuation.resume(returning: .failed("Replaced by a newer generation"))
        return await withCheckedContinuation { continuation in
            waiter = (generation, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: Self.loadTimeout)
                guard let self, let waiter = self.waiter, waiter.generation == generation else { return }
                self.waiter = nil
                waiter.continuation.resume(returning: .failed(self.failureSummary("The screen didn't confirm the new generation")))
            }
        }
    }

    private func resolve(_ generation: Int?, _ result: ShowResult) {
        guard let waiter, generation == nil || waiter.generation == generation else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: result)
    }

    // MARK: Page events

    private func handle(_ event: WebBridge.PageEvent) {
        switch event {
        case .ready(let generation):
            watchdog?.cancel()
            status = .ready
            if let generation { pageGeneration = generation }
            log.info("screen ready (generation \(generation ?? -1))")
            resolve(generation, .applied(changed: []))
        case .failed(let generation, let message):
            record("error", message)
            pageFailed(generation: generation ?? pageGeneration ?? 0, message: message)
        case .hot(let generation, let error):
            if let error {
                record("error", error)
                resolve(generation, .failed(error))
            } else {
                pageGeneration = generation
                resolve(generation, .applied(changed: []))
            }
        case .log(let level, let message):
            record(level, message)
        }
    }

    private func pageFailed(generation: Int, message: String) {
        watchdog?.cancel()
        log.error("screen of generation \(generation) failed: \(message)")
        Journal.note("screen_failed", ["generation": "\(generation)", "error": message])
        if waiter != nil {
            status = .failed(message)
            resolve(nil, .failed(message))
            return
        }
        guard recoverOnFailure else {
            status = .failed(message)
            return
        }
        Task {
            if let target = await AppModel.shared.recoverScreen(failed: generation, message: message) {
                load(generation: target, recover: false)
            } else {
                status = .failed(message)
            }
        }
    }

    private func record(_ level: String, _ message: String) {
        guard level == "error" || level == "warn" else { return }
        log.notice("page \(level): \(message)")
        errors.append("[\(level)] \(message)")
        if errors.count > 20 { errors.removeFirst(errors.count - 20) }
    }

    private func failureSummary(_ headline: String) -> String {
        let recent = errors.suffix(3)
        return recent.isEmpty ? headline + "." : headline + ":\n" + recent.joined(separator: "\n")
    }
}

extension WebUI: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == UISchemeHandler.scheme || url.scheme == "about" { return .allow }
        // Links leave through an in-app Safari page, never by replacing Mycroft's screen.
        bridge?.present(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record("error", "Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        record("error", "The screen didn't load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("web content process terminated; reloading")
        Journal.note("screen_process_terminated")
        reload()
    }
}

/// The web view in SwiftUI.
struct WebScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WebUI.shared.makeWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

extension WKWebView {
    /// Drops WebKit's form bar (previous / next / done) above the keyboard: the screen has its own composer, and the
    /// bar would leave a gap between them. WebKit has no setting for it, so the web view's content view gets a
    /// subclass whose `inputAccessoryView` is nil.
    func hideInputAccessory() {
        guard let content = scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }) else { return }
        let base: AnyClass = type(of: content)
        let name = "\(NSStringFromClass(base))_MycroftNoAccessory"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let created = objc_allocateClassPair(base, name, 0) {
            let none: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            class_addMethod(created, #selector(getter: UIResponder.inputAccessoryView), imp_implementationWithBlock(none), "@@:")
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass { object_setClass(content, subclass) }
    }
}
