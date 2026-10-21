import Foundation
import PiDurableKit
import Testing

@testable import Mycroft

/// The screen runs the agent's tools through its own conversation, with a local model that asks for exactly them.
@Suite("Screen tools")
@MainActor
struct ScreenToolsTests {
    @Test(.timeLimit(.minutes(2)))
    func theScreenRunsTheAgentsTools() async throws {
        let models = Models(builtinProviders: false)
        try await ScreenTools.register(on: models)
        let echo = Tool("echo", description: "Says the word back", parameters: .object(["word": .string("A word")])) {
            (args: [String: String], _) in "echo \(args["word"] ?? "")"
        }
        let fail = Tool("fail", description: "Always fails") { (_: ToolCallContext) -> String in throw ToolError("nope") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "screen-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try await Harness.open(
            .sqlite(at: folder.appending(path: "test.sqlite")), models: models,
            extensions: [Extension("test", tools: [echo, fail]), .codemode()], settings: AppModel.settings)
        let screen = ScreenTools()

        let tools = try await screen.list(harness)
        #expect(Set(tools.compactMap { $0["name"] as? String }).isSuperset(of: ["echo", "fail", "codemode"]))

        let one = try await screen.call([.init(name: "echo", arguments: ["word": "hi"])], harness: harness)
        #expect(one.first?["ok"] as? Bool == true)
        #expect(one.first?["text"] as? String == "echo hi")

        // Several at once, in order; a failing one says so.
        let two = try await screen.call(
            [.init(name: "fail", arguments: [:]), .init(name: "echo", arguments: ["word": "second"])], harness: harness)
        #expect(two.map { $0["ok"] as? Bool } == [false, true])
        #expect(two.last?["text"] as? String == "echo second")

        // Calls from several places at once run one request after another.
        let a = Task { try await screen.call([.init(name: "echo", arguments: ["word": "a"])], harness: harness).first?["text"] as? String }
        let b = Task { try await screen.call([.init(name: "echo", arguments: ["word": "b"])], harness: harness).first?["text"] as? String }
        #expect(try await a.value == "echo a")
        #expect(try await b.value == "echo b")

        // Code mode: a script that calls the other tools.
        let script = try await screen.call(
            [.init(name: "codemode", arguments: ["code": "const said = await tools.echo({ word: 'scripted' }); return said"])],
            harness: harness)
        print("codemode: \(script)")
        #expect(script.first?["ok"] as? Bool == true)
        #expect((script.first?["text"] as? String)?.contains("echo scripted") == true)

        // The screen's conversation stays one, and isn't a thread.
        let screenConversation = try await harness.document(ScreenTools.document).conversation
        #expect(screenConversation != nil)
    }
}
