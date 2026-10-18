import Foundation
import PiDurableKit

/// One conversation in the thread list. Each thread is a Pi Durable conversation; this is its list metadata.
nonisolated struct ThreadMeta: Codable, Sendable, Hashable, Identifiable {
    var id: ConversationID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var archived = false
    /// The hands host this thread works on; nil means the phone only.
    var machine: String?

    static let untitled = "New thread"
}

nonisolated struct ThreadList: Codable, Sendable, Hashable {
    var items: [ThreadMeta] = []
}

nonisolated enum Threads {
    /// Session-scoped, so the list lives in the same durable store and commits as the conversations.
    static let document = Document("mycroft.threads", scope: .session, initial: ThreadList())

    /// A title from the first message: its first line, at most 48 characters.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 48 else { return trimmed.isEmpty ? ThreadMeta.untitled : trimmed }
        return String(trimmed.prefix(47)) + "…"
    }
}

nonisolated enum Provider {
    static let codex: ProviderID = "openai-codex"
    static let defaultModel = ModelRef(provider: codex, modelId: "gpt-6.1-sol")
}
