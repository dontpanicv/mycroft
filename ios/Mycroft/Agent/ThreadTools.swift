import Foundation
import PiDurableKit

/// The infinite chat as a coordinator, after T3 Code's thread tools: it starts threads, follows them, tells them more
/// and stops them, only when the user asks. Only the infinite chat selects this extension (`AppModel.infiniteOnly`).
nonisolated enum ThreadTools {
    static let name = "mycroft.threads"

    struct StartArguments: Decodable, Sendable {
        var message: String
        var title: String?
    }

    struct ListArguments: Decodable, Sendable {
        var active: Bool?
    }

    struct ReadArguments: Decodable, Sendable {
        var id: Int
        var limit: Int?
        var before: Int?
    }

    struct SendArguments: Decodable, Sendable {
        var id: Int
        var message: String
        var steer: Bool?
    }

    struct StopArguments: Decodable, Sendable {
        var id: Int
    }

    static func makeExtension() -> Extension {
        Extension(name) {
            PromptSection("threads", tag: false, text: """
                You can coordinate the user's other threads: each is a separate agent with a conversation of its own, \
                in the thread list. Start, message or stop a thread only when the user's message asks for exactly \
                that ("create a thread for…", "let an agent do…", "tell that thread…", "stop it"). Never on your own \
                initiative, even when a thread would help: then do the work yourself, or answer. Check on threads \
                (thread_list, thread_read) when the user asks how they are going.
                A new thread knows only the message you give it: write a complete brief (the goal, what the user said \
                that matters, where things are, what to report back). Link a thread you mention as [its title](#/t/ID).
                """)

            Tool(
                "thread_start",
                description: "Only when the user asks for a new thread or agent: start a thread whose first message is your brief, and its run. It sees nothing of this chat but the brief.",
                parameters: .object([
                    "message": .string("The complete brief: the goal, what matters from this chat, what to report back"),
                    "title": .string("A short title for the thread list (default: the message's first line)").optional,
                ])
            ) { (args: StartArguments, call) -> String in
                guard !args.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("Give the thread a message.") }
                let meta = try await AppModel.shared.startThread(with: args.message, parent: call.conversationId, title: args.title)
                return "Started thread \(meta.id): [\(meta.title)](#/t/\(meta.id))."
            }

            Tool(
                "thread_list",
                description: "Only when the user asks about threads: the recent threads, newest first, with their status (working, done, failed, stopped, idle).",
                parameters: .object(["active": .boolean("Only the working ones").optional]),
                replay: .safe
            ) { (args: ListArguments, call) -> String in
                let app = await AppModel.shared
                var lines: [String] = []
                for meta in await app.threads.filter({ !$0.archived && $0.infinite != true }).prefix(30) {
                    let busy = await app.isBusy(meta)
                    if args.active == true, !busy { continue }
                    lines.append(line(meta, busy: busy, coordinator: call.conversationId))
                }
                return lines.isEmpty ? "No threads." : lines.joined(separator: "\n")
            }

            Tool(
                "thread_read",
                description: "Only when the user asks how a thread is going: its status and latest messages, newest last.",
                parameters: .object([
                    "id": .integer("The thread"),
                    "limit": .integer("How many entries (default 10, at most 50)").optional,
                    "before": .integer("Read entries before this one (the previous read says)").optional,
                ]),
                replay: .safe
            ) { (args: ReadArguments, call) -> String in
                let (meta, conversation) = try await thread(args.id)
                let page = try await conversation.entries(
                    through: args.before.map { EntryID($0 - 1) }, limit: min(max(args.limit ?? 10, 1), 50))
                let entries = page.items.reversed()
                let busy = await AppModel.shared.isBusy(meta)
                var text = line(meta, busy: busy, coordinator: call.conversationId) + "\n" + transcript(Array(entries))
                if page.next != nil, let oldest = entries.first { text += "\n(older: thread_read with before: \(oldest.id))" }
                return text
            }

            Tool(
                "thread_send",
                description: "Only when the user asks to tell a thread something: send it a message, after its run (or, with steer, into the running one).",
                parameters: .object([
                    "id": .integer("The thread"),
                    "message": .string("What to tell it"),
                    "steer": .boolean("Hand it to the running run at its next step instead of after it").optional,
                ])
            ) { (args: SendArguments, _) -> String in
                let (meta, _) = try await thread(args.id)
                try await AppModel.shared.send(args.message, to: meta, whenBusy: args.steer == true ? .steer : .followUp)
                return "Sent to [\(meta.title)](#/t/\(meta.id))."
            }

            Tool(
                "thread_stop",
                description: "Only when the user asks to stop a thread: stop its run. Its queued messages wait.",
                parameters: .object(["id": .integer("The thread")]),
                replay: .safe
            ) { (args: StopArguments, _) -> String in
                let (meta, _) = try await thread(args.id)
                try await AppModel.shared.stop(meta)
                return "Stopped [\(meta.title)](#/t/\(meta.id))."
            }
        }
    }

    /// A thread of the list (not the infinite chat), and its conversation.
    private static func thread(_ id: Int) async throws -> (ThreadMeta, Conversation) {
        guard let meta = await AppModel.shared.thread(ConversationID(id)), meta.infinite != true,
            let conversation = try await AppModel.shared.conversation(meta.id)
        else { throw Failure("No thread \(id); thread_list lists them.") }
        return (meta, conversation)
    }

    // MARK: Text

    /// `id · title · status · updated …`, and whether this chat started it.
    static func line(_ meta: ThreadMeta, busy: Bool, coordinator: ConversationID) -> String {
        let status = busy ? "working" : meta.outcome?.rawValue ?? "idle"
        let updated = meta.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
        return "\(meta.id) · \(meta.title) · \(status) · updated \(updated)" + (meta.parent == coordinator ? " · started here" : "")
    }

    /// The entries' messages as `[id] author: text`, each clipped (a tool's more).
    static func transcript(_ entries: [Entry]) -> String {
        entries.flatMap { entry in
            (entry.model ?? []).filter(Memory.said).map { message in
                let limit = if case .toolResult = message { 500 } else { 2_000 }
                return "[\(entry.id)] " + Memory.clip(Memory.show(message), limit)
            }
        }.joined(separator: "\n")
    }
}
