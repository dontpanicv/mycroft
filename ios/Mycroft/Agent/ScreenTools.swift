import Foundation
import PiDurableKit

/// The screen calls the agent's tools (docs/decisions/0015-the-screen-calls-tools.md).
///
/// A tool runs inside a durable call (the harness, the machines, its output), and outside a model's turn there is
/// none. So the screen's calls go through a conversation of their own whose model is local: it answers each request
/// with exactly the tool calls the screen asked for, and ends the turn once their results are in. Every agent tool
/// (native, the active generation's JavaScript tools, code mode) runs as it runs for the agent, results come back to
/// the page, and nothing reaches a real model.
///
/// Calls are stored like any tool call, so this is for actions and occasional reads. Frequent reads (a dashboard
/// refreshing every few seconds) use `machines.exec`, which stores nothing.
@MainActor
final class ScreenTools {
    static let shared = ScreenTools()

    /// The local model of the screen's conversation.
    nonisolated static let model = ModelRef(provider: "mycroft-screen", modelId: "tools")

    nonisolated struct Screen: Codable, Sendable, Hashable {
        var conversation: ConversationID?
    }

    /// Which conversation is the screen's, kept with the conversations themselves.
    nonisolated static let document = Document("mycroft.screen", scope: .session, initial: Screen())

    nonisolated struct Call: Codable, Sendable {
        var name: String
        var arguments: JSONObject
    }

    nonisolated struct Request: Codable, Sendable {
        var id: String
        var calls: [Call]
    }

    /// The previous request: they run one at a time, in order (a request may hold several calls, run in parallel).
    private var tail: Task<Void, Never>?

    /// Registers the local model; done once, before the harness opens.
    nonisolated static func register(on models: Models) async throws {
        let provider = FauxProvider(id: model.provider, models: [.init(id: model.modelId, name: "Screen tools")])
        try await models.register(provider)
        try await provider.respond { messages, _ in
            // The screen's request is the last user message; after the tools' results, the turn ends.
            guard case .user(let message) = messages.last,
                let request = try? JSONDecoder().decode(Request.self, from: Data(message.text.utf8))
            else { return .text("") }
            return FauxResponse(request.calls.enumerated().map { index, call in
                .toolCall(call.name, call.arguments, id: "\(request.id)-\(index)")
            })
        }
    }

    /// The agent's tools, as the screen may call them.
    func list(_ harness: Harness) async throws -> [[String: Any]] {
        try await harness.registry().tools.map { item in
            [
                "name": item.tool.name, "description": item.tool.description, "extension": item.extension,
                "parameters": WebBridge.object(item.tool.parameters) ?? [:],
            ]
        }
    }

    /// Runs `calls` (in parallel) and returns their results, in order.
    func call(_ calls: [Call], harness: Harness) async throws -> [[String: Any]] {
        let previous = tail
        let work = Task { () async throws -> [ToolResultMessage?] in
            await previous?.value
            return try await self.run(calls, harness: harness)
        }
        tail = Task { _ = try? await work.value }
        return zip(calls, try await work.value).map { call, result in
            guard let result else { return ["name": call.name, "ok": false, "text": "The call didn't run."] }
            var object: [String: Any] = [
                "name": result.toolName, "ok": !result.isError,
                "text": result.content.compactMap(\.text).joined(separator: "\n"),
                "details": result.details.flatMap { WebBridge.object($0) } ?? NSNull(),
            ]
            let images = result.content.compactMap { block -> [String: String]? in
                guard case .image(let image) = block else { return nil }
                return ["mimeType": image.mimeType, "data": image.data]
            }
            if !images.isEmpty { object["images"] = images }
            return object
        }
    }

    /// Submits the calls as one request and returns their results, in order (`nil`: a call that didn't run).
    private func run(_ calls: [Call], harness: Harness) async throws -> [ToolResultMessage?] {
        guard !calls.isEmpty else { return [] }
        let conversation = try await conversation(harness)
        let request = Request(id: String(UUID().uuidString.prefix(8)).lowercased(), calls: calls)
        try await conversation.submit(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)).wait()
        var results: [String: ToolResultMessage] = [:]
        for entry in try await conversation.entries(limit: calls.count * 2 + 8).items {
            if let result = entry.toolResult, result.toolCallId.hasPrefix(request.id + "-") { results[result.toolCallId] = result }
        }
        // Each request starts a fresh context: the local model reads only the last message anyway.
        try? await conversation.reset()
        return calls.indices.map { results["\(request.id)-\($0)"] }
    }

    /// The screen's conversation, made once and kept.
    private func conversation(_ harness: Harness) async throws -> Conversation {
        if let id = try await harness.document(Self.document).conversation, let conversation = try await harness.conversation(id) {
            return conversation
        }
        let conversation = try await harness.createConversation(agent: AgentChange(model: Self.model))
        try await harness.update(Self.document) { $0.conversation = conversation.id }
        return conversation
    }
}
