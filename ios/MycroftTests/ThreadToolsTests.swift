import Foundation
import PiDurableKit
import Testing

@testable import Mycroft

@Suite("The infinite chat's thread tools")
struct ThreadToolsTests {
    /// Only a conversation that selects the infinite chat's extensions is offered the thread tools and the memory.
    @Test(.timeLimit(.minutes(2)))
    func onlyTheInfiniteChatHasThem() async throws {
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let folder = FileManager.default.temporaryDirectory.appending(path: "thread-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let echo = Tool("echo", description: "Says the word back") { (_: ToolCallContext) -> String in "echo" }
        let extensions = [Extension("test", tools: [echo]), Memory.makeExtension(), ThreadTools.makeExtension()]
        var settings = AppModel.settings
        settings.extensions = extensions.map(\.name).filter { !AppModel.infiniteOnly.contains($0) }
        let harness = try await Harness.open(.sqlite(at: folder.appending(path: "test.sqlite")), models: models, extensions: extensions, settings: settings)

        let mine: Set<String> = ["thread_start", "thread_list", "thread_read", "thread_send", "thread_stop", "memory_zoom"]
        let thread = try await harness.createConversation(agent: AgentChange(model: faux.model))
        let regular = try await thread.agent().tools
        #expect(regular.contains("echo") && mine.isDisjoint(with: regular))
        let infinite = try await harness.createConversation(
            agent: AgentChange(model: faux.model, extensions: .edit(add: AppModel.infiniteOnly)))
        #expect(mine.isSubset(of: try await infinite.agent().tools))
        try await harness.close()
    }

    @Test func describesThreads() throws {
        var meta = ThreadMeta(id: ConversationID(7), title: "Fix the build", createdAt: .now, updatedAt: .now)
        #expect(ThreadTools.line(meta, busy: true, coordinator: ConversationID(1)).hasPrefix("7 · Fix the build · working · updated "))
        meta.outcome = .done
        meta.parent = ConversationID(1)
        let line = ThreadTools.line(meta, busy: false, coordinator: ConversationID(1))
        #expect(line.contains(" · done · ") && line.hasSuffix(" · started here"))

        let entries = try [
            #"{"id":3,"conversationId":7,"kind":"pi.user","model":[{"role":"user","content":"Fix it","timestamp":0}]}"#,
            #"{"id":4,"conversationId":7,"kind":"pi.assistant","model":[{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"toolCall","id":"c","name":"hands_exec","arguments":{"command":"make"}}],"timestamp":0}]}"#,
            #"{"id":5,"conversationId":7,"kind":"pi.tool-result","model":[{"role":"toolResult","toolCallId":"c","toolName":"hands_exec","content":[{"type":"text","text":"\#(String(repeating: "x", count: 900))"}],"isError":false,"timestamp":0}]}"#,
        ].map { try JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
        let lines = ThreadTools.transcript(entries).split(separator: "\n").map(String.init)
        #expect(lines[0] == "[3] user: Fix it")
        #expect(lines[1] == "[4] mycroft: On it." && lines[2] == #"→ hands_exec {"command":"make"}"#)
        #expect(lines[3].hasPrefix("[5] hands_exec: xxx") && lines[3].count == "[5] ".count + 500)
    }
}
