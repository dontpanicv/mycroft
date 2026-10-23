import Foundation
import PiDurableKit
import Testing
import os

@testable import Mycroft

@Suite("The infinite chat's memory")
struct MemoryTests {
    typealias Part = Memory.Part

    @Test func numbersTheTreeAsUniiChat() {
        // Slots in order: a leaf, its parent, the next leaf, the grandparent…
        #expect([Part(l: 0, i: 0), Part(l: 1, i: 0), Part(l: 0, i: 1), Part(l: 2, i: 0), Part(l: 0, i: 2)].map(\.slot) == [0, 1, 2, 3, 4])
        for slot in 0..<1_000 { #expect(Part(slot: slot).slot == slot) }
        let part = Part(l: 2, i: 3)
        #expect(part.first == 12 && part.last == 15 && part.ref == "12+4" && part.ctx == 16)
        #expect(part.halves == [Part(l: 1, i: 6), Part(l: 1, i: 7)] && part.parent == Part(l: 3, i: 1))
        #expect(Part.roots(13).map(\.ref) == ["0+8", "8+4", "12+1"])
        #expect(Part.zoomed(8, 4, count: 13) == Part(l: 2, i: 2))
        #expect(Part.zoomed(6, 4, count: 13) == nil && Part.zoomed(8, 3, count: 13) == nil && Part.zoomed(12, 2, count: 13) == nil)
    }

    @Test func mergesTheMostDueSiblingsWhoseParentIsBuilt() {
        let leaves = (0..<8).map { Part(l: 0, i: $0) }
        var built = Set(leaves + (0..<4).map { Part(l: 1, i: $0) })
        let merge = { Memory.merge(leaves, size: 800, low: 600, built: { built.contains($0) }, bytes: { _ in 100 }) }
        // The oldest pairs first, down to `low`.
        #expect(merge().parts.map(\.ref) == ["0+2", "2+2", "4+1", "5+1", "6+1", "7+1"])
        #expect(merge().size == 600)
        // A pair whose parent isn't built waits.
        built.remove(Part(l: 1, i: 0))
        #expect(merge().parts.map(\.ref) == ["0+1", "1+1", "2+2", "4+2", "6+1", "7+1"])
        // Neighbours that aren't siblings never merge.
        #expect(Memory.merge(Array(leaves[1...2]), size: 200, low: 0, built: { _ in true }, bytes: { _ in 100 }).parts.count == 2)
    }

    @Test func findsWhereTheRunBegins() {
        let user = Message.user(UserMessage(content: [.text("hi")]))
        let answer = Message.assistant(AssistantMessage(content: [.text("hello")]))
        let calling = Message.assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "1", name: "look", arguments: [:]))], stopReason: .toolUse))
        #expect(Memory.runStart([user, answer, user, calling, user]) == 2)
        #expect(Memory.runStart([user, calling]) == 0)
        #expect(Memory.runStart([user, answer]) == nil)
        // Pi's system messages (the prompt, the tools) are never the run's start, nor one of the chat's messages.
        let system = try! JSONDecoder().decode(Message.self, from: Data(#"{"role":"system","content":"You are Mycroft.","timestamp":0}"#.utf8))
        #expect(Memory.runStart([system, user, answer, system, user]) == 4)
        #expect(Memory.runStart([system, user]) == 1)
        #expect(!Memory.said(system) && Memory.said(user))
    }

    @Test func keepsTheTreeInFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let files = try Memory.Files(directory)
            try files.append(entry: 70, position: 0, role: .user)
            try files.append(entry: 71, position: 0, role: .assistant)
            try files.store(Part(l: 0, i: 0), "user: hi")
            try files.store(Part(l: 0, i: 1), "mycroft: hello, \"you\"\nthere")
            try files.store(Part(l: 1, i: 0), "a greeting")
            var views = Memory.Files.Views()
            views.view.parts = [Part(l: 1, i: 0)]
            try files.save(views)
        }
        let files = try Memory.Files(directory)
        #expect(files.count == 2)
        #expect(files.message(1)?.entry == 71 && files.message(1)?.role == .assistant && files.message(2) == nil)
        #expect(files.built() == [0, 1, 2])
        #expect(files.text(Part(l: 0, i: 1)) == "mycroft: hello, \"you\"\nthere")
        #expect(files.text(Part(l: 0, i: 2)) == nil)
        #expect(files.loadViews().view.parts == [Part(l: 1, i: 0)])
    }

    @Test func cutsAndPagesText() {
        let long = String(repeating: "é", count: 400)
        #expect(Memory.cut(long).utf8.count == Memory.node && Memory.cut(long).allSatisfy { $0 == "é" })
        #expect(Memory.over(long).contains("800 bytes"))
        #expect(Memory.flat("one\ntwo\r\n  three ") == "one two three")
        let text = String(repeating: "b", count: Memory.pageSize + 10)
        #expect(Memory.page(text, at: 0).hasSuffix("[more: memory_zoom again with at: \(Memory.pageSize)]"))
        #expect(Memory.page(text, at: Memory.pageSize) == "bbbbbbbbbb")
    }

    /// The real tree at its real size, on a local model: 1,024 messages longer than a line, every node built, the view
    /// merged under its high with detail fading with age, zoom from the oldest line down to the first message, and a
    /// request that sees the system prompt, the view, and the run.
    @Test(.timeLimit(.minutes(5)))
    func buildsAndServesALongChat() async throws {
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let line = String(repeating: "s", count: 400)
        let asked = OSAllocatedUnfairLock<[Message]?>(initialState: nil)
        try await faux.respond { messages, _ in
            guard messages.first?.text.hasPrefix(Memory.compactor) == false else { return .text(line) }  // a summary
            asked.withLock { $0 = messages }
            return .text("You said message 0.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try await Harness.open(
            .sqlite(at: folder.appending(path: "test.sqlite")), models: models, extensions: [Memory.makeExtension()],
            settings: AppModel.settings)
        let chat = try await harness.createConversation(agent: AgentChange(model: faux.model))
        let filler = String(repeating: "words ", count: 100)
        for k in 0..<512 {
            try await chat.write(EntryDraft(kind: .user, model: [.user(UserMessage(content: [.text("message \(2 * k): \(filler)")]))]))
            try await chat.write(EntryDraft(kind: .assistant, model: [.assistant(AssistantMessage(content: [.text("answer \(2 * k + 1): \(filler)")]))]))
        }

        let tree = try #require(Memory.open(chat.id, harness: harness, models: models, summarizer: faux.model, in: folder))
        try await tree.sync()
        while await tree.status.unbuilt > 0 { try await Task.sleep(for: .milliseconds(100)) }
        let (count, _, view) = await tree.status
        #expect(count == 1_024)
        // The view covers the chat once, oldest first, older lines broader.
        #expect(view.first?.first == 0 && view.last?.last == 1_023)
        #expect(zip(view, view.dropFirst()).allSatisfy { $0.last + 1 == $1.first && $0.l >= $1.l })
        #expect(view.first!.l >= 3 && view.last!.l == 0)

        // Zoom from the oldest line down to message 0, whole.
        var part = view[0]
        while part.l > 0 {
            let halves = try await tree.zoom(part.first, 1 << part.l, at: 0)
            #expect(halves.split(separator: "\n").map { $0.prefix(while: { $0 != "|" }) } == part.halves.map { Substring($0.ref) })
            part = part.halves[0]
        }
        let first = try await tree.zoom(0, 1, at: 0)
        #expect(first.hasPrefix("0+1|user: message 0: words"))

        // A request of the chat: Pi's system message, the view, then the run.
        try await chat.submit("What did I say first?")
        while asked.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(100)) }
        let messages = try #require(asked.withLock { $0 })
        #expect(messages.count == 3)
        guard messages.count == 3, case .system = messages[0], case .user(let memory) = messages[1], case .user(let run) = messages[2] else { return }
        #expect(memory.text.hasPrefix(Memory.header) && memory.text.contains("\n\(view[0].ref)|"))
        #expect(memory.text.utf8.count < Memory.high + 20_000)
        #expect(run.text == "What did I say first?")
    }
}
