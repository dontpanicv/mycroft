import Foundation
import PiDurableKit
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

    /// Makes state.json look as it did before generations recorded their layout.
    private func forgetLayout(of agent: URL) throws {
        let url = agent.appending(path: "state.json")
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        state["layout"] = nil
        try JSONSerialization.data(withJSONObject: state).write(to: url)
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

    /// A draft that changes only the screen has no extension.js of its own (generations keep only what changed): it
    /// activates with the app's.
    @Test func screenOnlyDraftActivates() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        try await store.write("ui/screens/cpu.js", content: "export const cpu = 1")
        #expect(await store.hasDraft)
        let (_, next) = try await store.draftExtension()
        #expect(next == 1)
        #expect(await store.draftUIChanges() == ["screens/cpu.js"])
        #expect(try await store.promoteDraft(note: "cpu") == 1)
        // The next screen-only draft starts from generation 1, which has no extension.js either.
        try await store.write("ui/screens/cpu.js", content: "export const cpu = 2")
        #expect(try await store.draftExtension().generation == 2)
    }

    /// After a switch back to an older generation, the next one branches from it.
    @Test func generationsRecordWhatTheyWereMadeFrom() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        try await store.write("ui/a.js", content: "1")
        #expect(try await store.promoteDraft(note: "one") == 1)
        try await store.write("ui/a.js", content: "2")
        #expect(try await store.promoteDraft(note: "two") == 2)
        try await store.activate(0)
        try await store.write("ui/b.js", content: "3")
        #expect(try await store.promoteDraft(note: "three") == 3)
        let parents = await store.state.history.map(\.parent)
        #expect(parents == [nil, 0, 1, 0])
        // A draft thrown away leaves no parent behind.
        try await store.write("ui/b.js", content: "4")
        try await store.discardDraft()
        #expect(await store.state.draftParent == nil)
    }

    /// Generations from before parents were recorded get theirs from their files: a draft starts as a copy of its
    /// parent, so a generation has all of its parent's files.
    @Test func parentsOfOlderGenerationsAreInferred() async throws {
        let agent = root.appending(path: "agent")
        let layout = [1: ["ui/style.css"], 2: ["ui/style.css", "ui/app.js"], 3: ["ui/cpu.js"], 4: ["ui/cpu.js", "ui/threads.js"]]
        for (generation, files) in layout {
            for file in files {
                let url = agent.appending(path: "generations/\(generation)/\(file)")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "generation \(generation)".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        try FileManager.default.createDirectory(at: agent.appending(path: "generations/0"), withIntermediateDirectories: true)
        let history = (0...4).map { #"{"generation": \#($0), "note": "n", "createdAt": "2026-10-20T10:00:00Z"}"# }
        let state = #"{"active": 4, "lastGood": 4, "bootAttempts": 0, "history": [\#(history.joined(separator: ","))]}"#
        try state.write(to: agent.appending(path: "state.json"), atomically: true, encoding: .utf8)

        let store = GenerationStore(root: agent)
        try await store.bootstrap(bundled: try bundled())
        #expect(await store.state.history.map(\.parent) == [nil, 0, 1, 0, 3])
        // Kept: reopening reads them back.
        #expect(await GenerationStore(root: agent).state.history.map(\.parent) == [nil, 0, 1, 0, 3])
    }

    /// A fresh start forgets every generation and the draft, and starts again from the app's own.
    @Test func resetStartsAgainFromGenerationZero() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        try await store.write("ui/a.js", content: "1")
        _ = try await store.promoteDraft(note: "one")
        try await store.write("ui/a.js", content: "2")
        try await store.reset()
        try await store.bootstrap(bundled: try bundled())
        #expect(await store.state.history.map(\.generation) == [0])
        #expect(await store.state.active == 0)
        #expect(await !store.hasDraft)
        #expect(await GenerationStore(root: root.appending(path: "agent")).state.history.count == 1)
    }

    @Test func aGenerationThatDoesntExistHasNoExtension() async throws {
        let store = GenerationStore(root: root.appending(path: "agent"))
        try await store.bootstrap(bundled: try bundled())
        _ = try await store.extensionFor(generation: 0)
        await #expect(throws: SelfError.self) { try await store.extensionFor(generation: 42) }
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
        try forgetLayout(of: agent)
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

/// A fresh start's new database: the paired machines and nothing else.
@Suite("Fresh start")
struct FreshStartTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "mycroft-fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
    var database: URL { folder.appending(path: "mycroft.sqlite") }

    private func seed() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try await Session.open(.sqlite(at: database))
        try await session.update(Machines.document) { $0.items = [MachinesTests.machine("bender-2")] }
        try await session.update(Threads.document) {
            $0.items = [ThreadMeta(id: ConversationID(7), title: "Old", createdAt: .now, updatedAt: .now)]
        }
        try await session.close()
    }

    private func read() async throws -> (machines: [String], threads: Int) {
        let session = try await Session.open(.sqlite(at: database))
        let machines = try await session.document(Machines.document).items.map(\.name)
        let threads = try await session.document(Threads.document).items.count
        try await session.close()
        return (machines, threads)
    }

    @Test func keepsThePairedMachines() async throws {
        try await seed()
        var swapped = false
        #expect(try await AppModel.freshDatabase(at: database, beforeSwap: { swapped = true }) == nil)
        #expect(swapped)
        let after = try await read()
        #expect(after.machines == ["bender-2"])
        #expect(after.threads == 0)
    }

    /// A failure before the swap leaves the old database as it was, and the next try still keeps the machines.
    @Test func aFailedTryChangesNothing() async throws {
        try await seed()
        struct Failed: Error {}
        await #expect(throws: Failed.self) { try await AppModel.freshDatabase(at: database, beforeSwap: { throw Failed() }) }
        #expect(try await read().threads == 1)
        _ = try await AppModel.freshDatabase(at: database, beforeSwap: {})
        let after = try await read()
        #expect(after.machines == ["bender-2"] && after.threads == 0)
    }
}
