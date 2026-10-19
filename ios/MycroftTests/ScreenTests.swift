import Foundation
import Testing

@testable import Mycroft

@Suite("Screen files")
struct ScreenFileTests {
    @Test func findsSyntaxErrorsInModules() {
        let good = """
            import { html, useState } from '/lib/preact.js'
            import {
            \tLabel,
            } from '../lib.js'
            export function A() { return html`<p>${1}</p>` }
            export default A
            export { A as B }
            """
        #expect(UIPreview.syntaxError(inModule: good) == nil)
        let bad = "import { html } from '/lib/preact.js'\n\nexport function A( {\n"
        #expect(UIPreview.syntaxError(inModule: bad)?.contains("SyntaxError") == true)
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "mycroft-screen-\(UUID().uuidString)")

    private func bundled() throws -> URL {
        let folder = root.appending(path: "bundled")
        try FileManager.default.createDirectory(at: folder.appending(path: "ui/screens"), withIntermediateDirectories: true)
        try "module.exports = 0;".write(to: folder.appending(path: "extension.js"), atomically: true, encoding: .utf8)
        try "<html>".write(to: folder.appending(path: "ui/index.html"), atomically: true, encoding: .utf8)
        try "export const a = 1".write(to: folder.appending(path: "ui/screens/a.js"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func generationsWithoutAScreenInheritGenerationZerosAndDraftsCopyIt() async throws {
        let agent = root.appending(path: "agent")
        let store = GenerationStore(root: agent)
        try await store.bootstrap(bundled: try bundled())
        // An older generation: only extension.js, like the ones made before the screen moved into generations.
        try FileManager.default.removeItem(at: agent.appending(path: "generations/0/ui"))
        #expect(try await store.read("ui/screens/a.js") == "export const a = 1")
        #expect(try await store.list().contains("ui/index.html"))

        try await store.write("ui/screens/a.js", content: "export const a = 2")
        #expect(FileManager.default.fileExists(atPath: agent.appending(path: "draft/ui/index.html").path), "the draft is a full tree")
        #expect(await store.draftUIChanges() == ["screens/a.js"])
        #expect(try await store.diff().contains("+1: export const a = 2"))

        let generation = try await store.promoteDraft(note: "a = 2")
        #expect(await store.uiChanges(from: 0, to: generation) == ["screens/a.js"])
        #expect(await store.uiChanges(from: generation, to: generation) == [])
    }

    @Test func schemeServesGenerationsDraftAndRuntimeOnly() throws {
        let bundled = try bundled()
        let agent = root.appending(path: "agent")
        let ui = agent.appending(path: "generations/4/ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try "own".write(to: ui.appending(path: "app.js"), atomically: true, encoding: .utf8)
        let handler = UISchemeHandler(root: agent, bundled: bundled)

        #expect(handler.resolve(URL(string: "mycroft-ui://app/g/4/app.js")!) == ui.appending(path: "app.js"))
        #expect(handler.resolve(URL(string: "mycroft-ui://app/g/4/screens/a.js")!) == bundled.appending(path: "ui/screens/a.js"))
        #expect(handler.resolve(URL(string: "mycroft-ui://app/draft/index.html")!) == bundled.appending(path: "ui/index.html"))
        #expect(handler.resolve(URL(string: "mycroft-ui://app/g/4/../../../state.json")!) == nil)
        #expect(handler.resolve(URL(string: "mycroft-ui://app/g/4/%2E%2E/x")!) == nil)
        #expect(handler.resolve(URL(string: "mycroft-ui://app/g/x/app.js")!) == nil)
        #expect(handler.resolve(URL(string: "mycroft-ui://app/other/app.js")!) == nil)
        #expect(handler.resolve(URL(string: "mycroft-ui://app/lib/preact.js")!) != nil)
        #expect(handler.resolve(URL(string: "mycroft-ui://app/lib/fonts/JetBrainsMono.ttf")!) != nil)
        #expect(UISchemeHandler.contentType("js").hasPrefix("text/javascript"))
    }
}

/// Renders real drafts off-screen in the test host: the check that keeps a broken screen from going live.
@Suite("Screen check", .serialized)
@MainActor
struct ScreenCheckTests {
    private let store = AppModel.shared.generations

    private func withDraft(_ files: [String: String], _ body: () async throws -> Void) async throws {
        await AppModel.shared.start()
        try await store.discardDraft()
        for (path, content) in files { try await store.write(path, content: content) }
        do {
            try await body()
        } catch {
            try? await store.discardDraft()
            throw error
        }
        try await store.discardDraft()
    }

    @Test func aWorkingDraftRendersWithAPicture() async throws {
        try await withDraft(["SELF.md": "# unchanged screen"]) {
            let result = await UIPreview.run(route: "#/settings", snapshot: true)
            #expect(result.outcome == .rendered, "\(result.summary)")
            #expect(result.problem == nil, "\(result.summary)")
            #expect((result.image?.count ?? 0) > 10_000)
        }
    }

    @Test func aSyntaxErrorIsCaught() async throws {
        try await withDraft(["ui/screens/pair.js": "export function Pair( {"]) {
            let result = await UIPreview.run(snapshot: false)
            #expect(result.problem != nil)
            #expect(result.summary.contains("ui/screens/pair.js:1"), "\(result.summary)")
            print("CHECK: \(result.summary)")
        }
    }

    @Test func aRenderErrorIsCaught() async throws {
        await AppModel.shared.start()
        try await store.discardDraft()
        let app = try await store.read("ui/app.js")
        let broken = app.replacingOccurrences(of: "function App() {", with: "function App() {\n\tnull.boom()")
        try await withDraft(["ui/app.js": broken]) {
            let result = await UIPreview.run(snapshot: false)
            #expect(result.outcome == .failed)
            #expect(result.summary.contains("boom") || result.summary.contains("null"), "\(result.summary)")
            print("CHECK: \(result.summary)")
        }
    }
}

/// The screen on display in the test host takes new generations in place, keeps its screen when one is broken, and
/// reloads itself fully when boot.js changes. (Adds "Screen test" generations to the host's history.)
@Suite("Hot reload", .serialized)
@MainActor
struct HotReloadTests {
    @Test func swapsInPlaceRefusesBrokenScreensAndReloadsForBootChanges() async throws {
        await AppModel.shared.start()
        for _ in 0..<150 where WebUI.shared.status != .ready { try await Task.sleep(for: .milliseconds(100)) }
        try #require(WebUI.shared.status == .ready)
        let store = AppModel.shared.generations
        let start = await store.state.active
        try await store.discardDraft()

        // A style change swaps in place.
        try await store.write("ui/style.css", content: try await store.read("ui/style.css") + "\n/* screen test */\n")
        let good = try await store.promoteDraft(note: "Screen test: style")
        #expect(await WebUI.shared.show(generation: good) == .applied(changed: ["style.css"]))
        #expect(WebUI.shared.pageGeneration == good)

        // A screen that throws while rendering is refused; the page keeps the previous one.
        let app = try await store.read("ui/app.js")
        try await store.write("ui/app.js", content: app.replacingOccurrences(of: "function App() {", with: "function App() {\n\tnull.boom()"))
        let bad = try await store.promoteDraft(note: "Screen test: broken")
        let refused = await WebUI.shared.show(generation: bad)
        guard case .failed(let message) = refused else { Issue.record("a broken screen went live: \(refused)"); return }
        print("REFUSED: \(message)")
        #expect(WebUI.shared.pageGeneration == good)
        #expect(WebUI.shared.status == .ready)

        // boot.js can't swap itself: the page reloads from the new generation.
        try await store.write("ui/app.js", content: app)
        try await store.write("ui/boot.js", content: try await store.read("ui/boot.js") + "\n// screen test\n")
        let boot = try await store.promoteDraft(note: "Screen test: boot")
        #expect(await WebUI.shared.show(generation: boot) == .applied(changed: ["app.js", "boot.js", "style.css"]) || WebUI.shared.pageGeneration == boot)
        #expect(WebUI.shared.pageGeneration == boot)

        _ = try await AppModel.shared.rollBack(to: start)
        _ = await WebUI.shared.show(generation: start)
    }
}
