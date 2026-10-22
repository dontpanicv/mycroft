import Foundation
import PiDurableKit
import Testing

@testable import Mycroft

/// Which machine a name means, and what the model is told about the paired machines.
@Suite("Machines")
@MainActor
struct MachinesTests {
    nonisolated static func machine(_ name: String) -> Machine {
        Machine(
            name: name, hostname: nil, addresses: ["10.0.0.2"], port: 59665, certSha256: "", os: "macos", arch: "aarch64",
            version: "0.4.0", pairedAt: .now)
    }

    @Test func namesMatchLooselyButNeverAmbiguously() {
        let list = MachineList(items: [Self.machine("bender-2"), Self.machine("GLaDOS"), Self.machine("Work Mac")])
        #expect(list.named("bender-2")?.name == "bender-2")
        #expect(list.named("Bender")?.name == "bender-2")
        #expect(list.named("bender 2")?.name == "bender-2")
        #expect(list.named("glados")?.name == "GLaDOS")
        #expect(list.named("work-mac")?.name == "Work Mac")
        #expect(list.named("mac") == nil)
        #expect(list.named("") == nil)
        // Two machines start with the same name: only the exact one.
        let twins = MachineList(items: [Self.machine("bender"), Self.machine("bender-2")])
        #expect(twins.named("bender")?.name == "bender")
        #expect(twins.named("bend") == nil)
    }

    /// The machines section is rendered before every request, so a machine paired later shows up in an older thread.
    @Test(.timeLimit(.minutes(2)))
    func everyRequestToldWhichMachinesArePaired() async throws {
        let models = Models(builtinProviders: false)
        let provider = FauxProvider(id: "test", models: [.init(id: "faux", name: "Faux")])
        try await models.register(provider)
        try await provider.respond { _, _ in .text("ok") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "machines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try await Harness.open(
            .sqlite(at: folder.appending(path: "test.sqlite")), models: models,
            extensions: [HandsTools.makeExtension()], settings: AppModel.settings)
        try await harness.update(Machines.document) { $0.items = [Self.machine("bender-2")] }
        let conversation = try await harness.createConversation(
            agent: AgentChange(model: ModelRef(provider: "test", modelId: "faux")))

        _ = try await conversation.submit("hi")
        try await conversation.waitForIdle()
        #expect(try await prompt(of: conversation).contains("bender-2"))

        try await harness.update(Machines.document) { $0.items.append(Self.machine("GLaDOS")) }
        _ = try await conversation.submit("again")
        try await conversation.waitForIdle()
        #expect(try await prompt(of: conversation).contains("GLaDOS"))
    }

    /// Everything the conversation's system entries have said, oldest first.
    private func prompt(of conversation: Conversation) async throws -> String {
        let entries = try await conversation.entries(order: .ascending, limit: 200).items
        let system = entries.filter { $0.is(.system) }
        let json = try JSONEncoder().encode(system.compactMap(\.model))
        return String(decoding: json, as: UTF8.self)
    }
}
