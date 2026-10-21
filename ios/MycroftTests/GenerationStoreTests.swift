import Foundation
import Testing

@testable import Mycroft

@Suite("Generations")
struct GenerationStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "mycroft-tests-\(UUID().uuidString)")

    private func bundled() throws -> URL {
        let folder = root.appending(path: "bundled")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "module.exports = 0;".write(to: folder.appending(path: "extension.js"), atomically: true, encoding: .utf8)
        try "# self".write(to: folder.appending(path: "SELF.md"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func draftPromotesToNextGeneration() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        #expect(await store.state.active == 0)

        try await store.write("extension.js", content: "module.exports = 1;")
        let diff = try await store.diff()
        #expect(diff.contains("+1: module.exports = 1;"))
        #expect(diff.contains("-1: module.exports = 0;"))

        let generation = try await store.promoteDraft(note: "count to one")
        #expect(generation == 1)
        #expect(await store.state.active == 1)
        #expect(try await store.read("extension.js") == "module.exports = 1;")
        await #expect(throws: SelfError.self) { try await store.draftExtension() }
    }

    @Test func crashLoopRollsBackToLastGood() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        try await store.markHealthy()
        try await store.write("extension.js", content: "throw new Error('boom')")
        _ = try await store.promoteDraft(note: "broken")

        for _ in 0..<GenerationStore.maxBootAttempts {
            #expect(try await store.beginBoot() == nil)
        }
        #expect(try await store.beginBoot() == 1)
        #expect(await store.state.active == 0)
    }

    @Test func rejectsPathsOutsideTheGeneration() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        await #expect(throws: SelfError.self) { try await store.write("../escape.js", content: "") }
        await #expect(throws: SelfError.self) { try await store.write("docs/pi-durable/README.md", content: "") }
    }

    /// A generation keeps what the agent changed; everything else, and the files that describe the app, follow the app.
    @Test func appUpdatesReachEveryGeneration() async throws {
        let agent = root.appending(path: "agent")
        let bundled = try bundled()
        try "screen v1".write(to: bundled.appending(path: "screen.js"), atomically: true, encoding: .utf8)
        let store = GenerationStore(root: agent)
        try await store.bootstrap(bundled: bundled)
        try await store.write("extension.js", content: "module.exports = 1;")
        _ = try await store.promoteDraft(note: "mine")
        await #expect(throws: SelfError.self) { try await store.write("SELF.md", content: "# mine") }
        // An older generation that copied the app's files, as generations used to: the copies go at the next start.
        try "screen v1".write(to: agent.appending(path: "generations/1/screen.js"), atomically: true, encoding: .utf8)
        try "# old self".write(to: agent.appending(path: "generations/1/SELF.md"), atomically: true, encoding: .utf8)
        let reopened = GenerationStore(root: agent)
        try await reopened.bootstrap(bundled: bundled)

        // The app updates.
        try "screen v2".write(to: bundled.appending(path: "screen.js"), atomically: true, encoding: .utf8)
        try "# new self".write(to: bundled.appending(path: "SELF.md"), atomically: true, encoding: .utf8)
        #expect(try await reopened.read("screen.js") == "screen v2")
        #expect(try await reopened.read("SELF.md") == "# new self")
        #expect(try await reopened.read("extension.js") == "module.exports = 1;")

        // A new draft holds only what the agent writes.
        try await reopened.write("other.js", content: "x")
        #expect(!FileManager.default.fileExists(atPath: agent.appending(path: "draft/screen.js").path))
        #expect(try await reopened.read("screen.js") == "screen v2")
    }

    @Test func stateSurvivesReopening() async throws {
        let agent = root.appending(path: "agent")
        let store = GenerationStore(root: agent)
        try await store.bootstrap(bundled: try bundled())
        try await store.write("extension.js", content: "module.exports = 2;")
        _ = try await store.promoteDraft(note: "second")

        let reopened = GenerationStore(root: agent)
        #expect(await reopened.state.active == 1)
        #expect(await reopened.state.history.map(\.note) == ["Shipped with the app", "second"])
    }
}

@Suite("Codex auth import")
struct DevImportTests {
    /// A JWT with `exp` and the ChatGPT account claim, unsigned (the import only reads claims).
    private func token(exp: Int, account: String) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return encode(["alg": "none"]) + "." + encode(["exp": exp, "https://api.openai.com/auth": ["chatgpt_account_id": account]]) + "."
    }

    @Test func convertsCodexAuthFile() throws {
        let access = token(exp: 2_000_000_000, account: "acct-123")
        let file = #"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(access)","refresh_token":"r-1","id_token":"x"}}"#
        let credential = try DevImport.codexCredential(from: Data(file.utf8))
        #expect(credential.json["type"]?.stringValue == "oauth")
        #expect(credential.json["refresh"]?.stringValue == "r-1")
        #expect(credential.json["accountId"]?.stringValue == "acct-123")
        #expect(credential.json["expires"]?.doubleValue == 2_000_000_000_000)
    }
}
