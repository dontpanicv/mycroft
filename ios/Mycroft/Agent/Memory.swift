import Foundation
import PiDurableKit
import os

/// The infinite chat's memory, after UniiChat's (github.com/VictorTaelin/UniiChat, Apache-2.0): a chat that never ends
/// and never forgets.
///
/// Over the chat's messages grows a binary tree: node (l, i) covers the messages i·2^l ..< (i+1)·2^l, a leaf is its
/// message in one line of at most `node` bytes (a short one is its own line), and a node above merges its two halves.
/// Each node builds in the background as soon as its halves are, on the summary model, and is kept for good (`Files`).
///
/// Every model request of the chat sees a view instead of its transcript (`beforeRequest`): lines covering the chat up
/// to where the run began, oldest first, then the run whole. Each message reached appends its leaf; past `high` bytes, a
/// batch merges the adjacent siblings whose parent is built and most due (oldest since its last message, in halves:
/// detail fades with age) down to half, so a view changes only at its end between batches (the provider's prompt
/// cache). `memory_zoom` opens a line into the two it was made from, down to the message whole.
nonisolated enum Memory {
    /// A line's most bytes.
    static let node = 512
    /// The chat's view merges past this many bytes, down to half; the summaries' own view (`seen`) past `seenHigh`.
    static let high = 128_000
    static let seenHigh = 32_000
    /// Summaries built at once, and tries for a line that fits.
    static let jobs = 8
    static let tries = 5
    /// What a leaf's summary reads of its message, in characters.
    static let sourceLimit = 32_000
    /// What `memory_zoom` returns of a message at once, in characters.
    static let pageSize = 16_000
    /// Entries in Pi's active transcript past which the chat compacts after a run: the view replaces that transcript
    /// for the model, so Pi's own thresholds (from the last request's tokens) never come, and only the screen and
    /// `beforeRequest` read it.
    static let trim = 200
    static let wait = "(not summarized yet: memory_zoom it)"

    static let header = """
        This is the infinite chat: one conversation with the user that never ends. <chat> holds everything said \
        before this run, oldest first, as lines `id+n|summary`: message id and the n-1 after it (n = 1: one message; \
        a short one as it was said). Older lines cover more messages. When a line only mentions something you need \
        (what was said, a decision, a past attempt, where a file is), open it with memory_zoom { id, n } before you guess, \
        ask or act: it gives the two lines it was made from, and n = 1 the message whole.
        """

    static let compactor = """
        You write the memory of an endless chat between the user and Mycroft, their AI agent. <chat> lists what came \
        before as lines `id+n|summary`, oldest first: message id and the n-1 after it. Answer with the one line asked \
        for and no other text. Keep what matters later: what the user asked or told, what Mycroft did, found or \
        answered, decisions, names, numbers, machines, file paths.
        """

    /// The trimmed transcript's summary: the view replaces it, so no model writes one.
    static let trimmed = "Earlier messages of this chat are in its memory lines (memory_zoom)."

    // MARK: The tree

    /// Node (l, i): the messages `first...last`.
    struct Part: Hashable, Sendable {
        var l: Int
        var i: Int

        init(l: Int, i: Int) {
            self.l = l
            self.i = i
        }

        /// Its place in `tree.index`: the nodes in order, as a complete binary tree's.
        init(slot: Int) {
            l = (slot + 1).trailingZeroBitCount
            i = (((slot + 1) >> l) - 1) / 2
        }

        var slot: Int { ((2 * i + 1) << l) - 1 }
        var first: Int { i << l }
        var last: Int { ((i + 1) << l) - 1 }
        var parent: Part { Part(l: l + 1, i: i >> 1) }
        var sibling: Part { Part(l: l, i: i ^ 1) }
        var halves: [Part] { l == 0 ? [] : [Part(l: l - 1, i: 2 * i), Part(l: l - 1, i: 2 * i + 1)] }
        /// Its zoom target, `id+n`.
        var ref: String { "\(first)+\(1 << l)" }
        /// The messages its summary's view reaches: those before a leaf, a merge's own.
        var ctx: Int { l == 0 ? i : last + 1 }

        /// The line `memory_zoom(id, n)` names, in a chat of `count` messages.
        static func zoomed(_ id: Int, _ n: Int, count: Int) -> Part? {
            guard n > 0, n & (n - 1) == 0, id >= 0, id % n == 0, id + n <= count else { return nil }
            return Part(l: n.trailingZeroBitCount, i: id / n)
        }

        /// The tree's roots: a node per power of two in the count, largest first.
        static func roots(_ count: Int) -> [Part] {
            var parts: [Part] = []
            var id = 0
            for l in stride(from: 40, through: 0, by: -1) where id + (1 << l) <= count {
                parts.append(Part(l: l, i: id >> l))
                id += 1 << l
            }
            return parts
        }
    }

    /// A view: its lines, oldest first, and whether a batch of merges is under way.
    struct View: Codable, Sendable, Equatable {
        var parts: [Part] = []
        var batch = false

        /// The message after its last line.
        var end: Int { parts.last.map { $0.last + 1 } ?? 0 }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            parts = try container.decode([[Int]].self, forKey: .parts).map { Part(l: $0[0], i: $0[1]) }
            batch = try container.decode(Bool.self, forKey: .batch)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(parts.map { [$0.l, $0.i] }, forKey: .parts)
            try container.encode(batch, forKey: .batch)
        }

        private enum CodingKeys: String, CodingKey { case parts, batch }
    }

    /// `parts` with their most due sibling pairs merged, as built parents allow, until `size` is at most `low`: most
    /// due is (t + 1) / 2^l - i, t the view's end (its age from its last message, in halves), the oldest of equals.
    static func merge(_ parts: [Part], size: Int, low: Int, built: (Part) -> Bool, bytes: (Part) -> Int) -> (parts: [Part], size: Int) {
        var parts = parts
        var size = size
        let t = Double(parts.last.map { $0.last + 1 } ?? 0)
        while size > low {
            var best: (due: Double, k: Int)?
            for k in parts.indices.dropLast() {
                let (a, b) = (parts[k], parts[k + 1])
                guard a.i % 2 == 0, b == a.sibling, built(a.parent) else { continue }
                let due = (t + 1) / Double(1 << a.l) - Double(a.i)
                if best.map({ due > $0.due }) ?? true { best = (due, k) }
            }
            guard let k = best?.k else { break }
            let up = parts[k].parent
            size += bytes(up) - bytes(parts[k]) - bytes(parts[k + 1])
            parts.replaceSubrange(k...(k + 1), with: [up])
        }
        return (parts, size)
    }

    /// Whether a message is one of the chat's (a leaf): the user's, an answer, a tool result; not a system message (the
    /// system prompt and the tools).
    static func said(_ message: Message) -> Bool {
        switch message {
        case .user, .assistant, .toolResult: true
        default: false
        }
    }

    /// Where the run asking begins: the user message after the last final answer (one with no tool call) and any system
    /// messages, or the first; `nil` if the messages end with an answer.
    static func runStart(_ messages: [Message]) -> Int? {
        var k = messages.count
        while k > 0 {
            if case .assistant(let message) = messages[k - 1], message.toolCalls.isEmpty { break }
            k -= 1
        }
        while k < messages.count, !said(messages[k]) { k += 1 }
        guard k < messages.count, case .user = messages[k] else { return nil }
        return k
    }

    // MARK: The agent's side

    private static let current = OSAllocatedUnfairLock<Tree?>(initialState: nil)

    /// The infinite chat's tree, if `conversation` is the infinite chat.
    static func tree(_ conversation: ConversationID) -> Tree? {
        current.withLock { $0?.conversation == conversation ? $0 : nil }
    }

    /// Opens the infinite chat's tree, kept in `directory`, and builds what its messages lack in the background.
    @discardableResult
    static func open(
        _ conversation: ConversationID, harness: Harness, models: Models, summarizer: ModelRef = Provider.defaultModel, in directory: URL
    ) -> Tree? {
        let log = Logger(subsystem: "dev.mycroft", category: "memory")
        do {
            let tree = try Tree(
                conversation, harness: harness, models: models, summarizer: summarizer, directory: directory.appending(path: "\(conversation)"))
            current.withLock { $0 = tree }
            Task {
                do { try await tree.sync() } catch { log.error("the memory could not catch up: \(error)") }
            }
            return tree
        } catch {
            log.error("the memory could not open: \(error)")
            return nil
        }
    }

    static func makeExtension() -> Extension {
        Extension("mycroft.memory") {
            Hook.beforeRequest { messages, context in
                guard let tree = tree(context.conversationId), let start = runStart(messages),
                    let chat = try await tree.view(endingWith: messages[start...].filter(said).count)
                else { return nil }
                // Pi's system messages carry the system prompt and the tools: they stay, the view takes the rest.
                return messages[..<start].filter { !said($0) } + [.user(UserMessage(content: [.text(chat)]))] + messages[start...]
            }

            Hook.beforeCompact { _, context in
                tree(context.conversationId) == nil ? nil : .summary(trimmed)
            }

            Tool(
                "memory_zoom",
                description: "Open a line id+n of the infinite chat's memory into the two lines of n/2 messages it was made from; n = 1 gives message id whole. A long message comes in pages from character at.",
                parameters: .object([
                    "id": .integer("The line's first message"),
                    "n": .integer("How many messages the line covers (default 1)").optional,
                    "at": .integer("Where to go on in a long message (the previous page says)").optional,
                ]),
                replay: .safe
            ) { (args: ZoomArguments, call) -> ToolResult in
                guard let tree = tree(call.conversationId) else { throw Failure("Only the infinite chat has memory lines.") }
                return ToolResult(output: [.text(try await tree.zoom(args.id, args.n ?? 1, at: args.at ?? 0))])
            }
        }
    }

    struct ZoomArguments: Decodable, Sendable {
        var id: Int
        var n: Int?
        var at: Int?
    }

    // MARK: Text

    /// A message as the summaries read it, tagged by its author.
    static func show(_ message: Message) -> String {
        let content = { (blocks: [ContentBlock]) in
            blocks.compactMap { block -> String? in
                switch block {
                case .text(let text): text
                case .image: "[image]"
                default: nil
                }
            }.joined()
        }
        switch message {
        case .user(let message): return "user: " + content(message.content)
        case .assistant(let message):
            let calls = message.toolCalls.map { call in
                let arguments = (try? JSONEncoder().encode(call.arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return "→ \(call.name) \(arguments)"
            }
            return "mycroft: " + ([message.text].filter { !$0.isEmpty } + calls).joined(separator: "\n")
        case .toolResult(let message): return "\(message.toolName): " + content(message.content)
        case .system(let message): return "system: " + message.text
        case .other: return ""
        }
    }

    /// Node (l, i)'s task, before its input.
    static func task(_ part: Part) -> String {
        let ruler = String(repeating: "-", count: node)
        guard part.l > 0 else {
            return """
                Compaction: compress message \(part.i) into one line of at most \(node) bytes (about 70 words), the \
                length of this ruler:
                \(ruler)
                <input>

                """
        }
        let n = 1 << (part.l - 1)
        return """
            Compaction: merge lines \(part.first)+\(n) and \(part.first + n)+\(n), adjacent, into one line of at most \
            \(node) bytes (about 70 words), the length of this ruler:
            \(ruler)
            <chat> may hold their messages, \(part.first) to \(part.last), in more detail: take details of them from \
            there too.
            <input>

            """
    }

    static func over(_ line: String) -> String {
        """
        Too long: your last line for this <input> was \(line.utf8.count) bytes, over the \(node)-byte limit. Write the \
        whole line again, cutting just enough of the least valuable items to fit before this cut:
        \(cut(line))| ← LIMIT
        """
    }

    /// A text's first `node` bytes.
    static func cut(_ text: String) -> String {
        var cut = String(decoding: Array(text.utf8.prefix(node)), as: UTF8.self)
        while cut.hasSuffix("\u{FFFD}") { cut.removeLast() }
        return cut
    }

    static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `text` at most `limit` characters: its start and its end.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = limit * 2 / 3
        return String(text.prefix(head)) + " … " + String(text.suffix(max(0, limit - head - 3)))
    }

    /// `pageSize` characters of `text` from `at`, saying where to go on.
    static func page(_ text: String, at: Int) -> String {
        let start = text.index(text.startIndex, offsetBy: max(0, at), limitedBy: text.endIndex) ?? text.endIndex
        let end = text.index(start, offsetBy: pageSize, limitedBy: text.endIndex) ?? text.endIndex
        let more = end < text.endIndex ? "\n[more: memory_zoom again with at: \(max(0, at) + pageSize)]" : ""
        return String(text[start..<end]) + more
    }
}

// MARK: - The tree's files

extension Memory {
    /// The tree on disk, as UniiChat keeps it: `main.index`, a 16-byte slot per message (its entry, its place in the
    /// entry, its role); `tree.log`, the nodes as JSON lines, appended; `tree.index`, a 16-byte slot per node by
    /// `Part.slot` (where its line is); `view.json`, the views, written over. The messages stay in Pi's entries.
    nonisolated final class Files {
        enum Role: UInt32 { case user, assistant, tool, other }

        struct Record: Codable {
            var l: Int
            var i: Int
            var text: String
        }

        struct Views: Codable, Equatable {
            var view = View()
            var seen = View()
        }

        private let main: FileHandle
        private let log: FileHandle
        private let index: FileHandle
        private let views: URL

        init(_ directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let handle = { (name: String) in
                let url = directory.appending(path: name)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                return try FileHandle(forUpdating: url)
            }
            main = try handle("main.index")
            log = try handle("tree.log")
            index = try handle("tree.index")
            views = directory.appending(path: "view.json")
        }

        deinit {
            try? main.close()
            try? log.close()
            try? index.close()
        }

        // Messages

        var count: Int { Int((try? main.seekToEnd()) ?? 0) / 16 }

        func message(_ i: Int) -> (entry: Int, position: Int, role: Role)? {
            guard i >= 0, let slot = Self.read(main, i) else { return nil }
            return (Int(slot.0), Int(slot.1), Role(rawValue: slot.2) ?? .other)
        }

        func append(entry: Int, position: Int, role: Role) throws {
            try Self.write(main, count, UInt64(entry), UInt32(position), role.rawValue)
        }

        // Nodes

        /// The slots of the nodes built.
        func built() -> Set<Int> {
            guard (try? index.seek(toOffset: 0)) != nil, let data = try? index.readToEnd() else { return [] }
            return Set((0..<(data.count / 16)).filter { k in
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: k * 16 + 12, as: UInt32.self) } == 1
            })
        }

        func text(_ part: Part) -> String? {
            guard let slot = Self.read(index, part.slot), slot.2 == 1, (try? log.seek(toOffset: slot.0)) != nil,
                let data = try? log.read(upToCount: Int(slot.1))
            else { return nil }
            return (try? JSONDecoder().decode(Record.self, from: data))?.text
        }

        func store(_ part: Part, _ text: String) throws {
            let line = try JSONEncoder().encode(Record(l: part.l, i: part.i, text: text))
            let offset = try log.seekToEnd()
            try log.write(contentsOf: line + Data("\n".utf8))
            try Self.write(index, part.slot, offset, UInt32(line.count), 1)
        }

        // Views

        func loadViews() -> Views {
            (try? Data(contentsOf: views)).flatMap { try? JSONDecoder().decode(Views.self, from: $0) } ?? Views()
        }

        func save(_ value: Views) throws {
            try JSONEncoder().encode(value).write(to: views, options: .atomic)
        }

        private static func read(_ handle: FileHandle, _ k: Int) -> (UInt64, UInt32, UInt32)? {
            guard (try? handle.seek(toOffset: UInt64(k * 16))) != nil, let data = try? handle.read(upToCount: 16), data.count == 16
            else { return nil }
            return data.withUnsafeBytes {
                ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
                    $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            }
        }

        private static func write(_ handle: FileHandle, _ k: Int, _ a: UInt64, _ b: UInt32, _ c: UInt32) throws {
            var data = Data()
            withUnsafeBytes(of: a.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: b.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: c.littleEndian) { data.append(contentsOf: $0) }
            try handle.seek(toOffset: UInt64(k * 16))
            try handle.write(contentsOf: data)
        }
    }
}

// MARK: - The tree at work

extension Memory {
    /// The infinite chat's tree: indexes its messages (`sync`), builds its nodes in the background, keeps its views.
    actor Tree {
        nonisolated let conversation: ConversationID
        private let harness: Harness
        private let models: Models
        private let summarizer: ModelRef
        private let files: Files
        private let log = Logger(subsystem: "dev.mycroft", category: "memory")

        private var count: Int
        /// The leaves built from the first on: the summaries' view reaches to them.
        private var leaves = 0
        private var built: Set<Int>
        private var ready: Set<Part> = []
        private var busy: Set<Part> = []
        /// Lines kept: the views' (others are read from `tree.log`).
        private var texts: [Int: String] = [:]
        private var views: Files.Views
        /// Why the last summary failed: none starts again until the next message.
        private var failure: String?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var syncing: Task<Void, Error>?

        init(_ conversation: ConversationID, harness: Harness, models: Models, summarizer: ModelRef, directory: URL) throws {
            self.conversation = conversation
            self.harness = harness
            self.models = models
            self.summarizer = summarizer
            files = try Files(directory)
            let count = files.count
            let built = files.built()
            var leaves = 0
            while built.contains(Part(l: 0, i: leaves).slot) { leaves += 1 }
            var ready = Set((0..<count).map { Part(l: 0, i: $0) }.filter { !built.contains($0.slot) })
            for slot in built {
                let part = Part(slot: slot)
                if built.contains(part.sibling.slot), !built.contains(part.parent.slot) { ready.insert(part.parent) }
            }
            (self.count, self.built, self.leaves, self.ready) = (count, built, leaves, ready)
            views = files.loadViews()
        }

        /// Indexes the messages written since, and builds what they need.
        func sync() async throws {
            if let syncing { return try await syncing.value }
            let task = Task { try await index() }
            syncing = task
            defer { syncing = nil }
            try await task.value
            failure = nil
            fit(next: true)
            pump()
        }

        private func index() async throws {
            guard let chat = try await harness.conversation(conversation) else { return }
            let newest = files.message(count - 1)?.entry
            var cursor: Cursor?
            repeat {
                let page = try await chat.entries(from: newest.map { EntryID($0 + 1) }, order: .ascending, limit: 200, after: cursor)
                for entry in page.items where entry.kind != .compaction && entry.kind != .reset {
                    for (position, message) in (entry.model ?? []).enumerated() where Memory.said(message) {
                        let role: Files.Role = switch message {
                        case .user: .user
                        case .assistant: .assistant
                        default: .tool
                        }
                        try files.append(entry: entry.id.rawValue, position: position, role: role)
                        ready.insert(Part(l: 0, i: count))
                        count += 1
                    }
                }
                cursor = page.next
            } while cursor != nil
        }

        /// The view a request of the chat sees, for a run of its last `run` messages: `nil` if none came before, or if
        /// the run doesn't start at a user message (the transcript and the index disagree).
        func view(endingWith run: Int) async throws -> String? {
            try await sync()
            let from = count - run
            guard from > 0, files.message(from)?.role == .user else { return nil }
            while leaves < from {
                if let failure, busy.isEmpty { throw Failure("The memory's summary failed: \(failure)") }
                await withCheckedContinuation { waiters.append($0) }
            }
            let lines = views.view.parts.filter { $0.last < from }.map { "\($0.ref)|\(Memory.flat(text($0) ?? Memory.wait))" }
            return Memory.header + "\n\n<chat>\n" + lines.joined(separator: "\n") + "\n</chat>"
        }

        /// The messages indexed, the nodes not built yet (ready or building), and the chat's view.
        var status: (count: Int, unbuilt: Int, view: [Part]) { (count, ready.count, views.view.parts) }

        func zoom(_ id: Int, _ n: Int, at: Int) async throws -> String {
            guard let part = Part.zoomed(id, n, count: count) else {
                let roots = Part.roots(count).map(\.ref).joined(separator: ", ")
                return "No line \(id)+\(n): n is a power of 2, id a multiple of n. The tree's roots: \(roots)."
            }
            guard n == 1 else { return part.halves.map { "\($0.ref)|\(Memory.flat(text($0) ?? Memory.wait))" }.joined(separator: "\n") }
            return "\(id)+1|" + Memory.page(try await message(id).map(Memory.show) ?? "(gone)", at: at)
        }

        // MARK: Building

        private func message(_ i: Int) async throws -> Message? {
            guard let slot = files.message(i), let chat = try await harness.conversation(conversation) else { return nil }
            let entry = try await chat.entries(from: EntryID(slot.entry), through: EntryID(slot.entry), limit: 1).items.first
            return entry?.model.flatMap { $0.indices.contains(slot.position) ? $0[slot.position] : nil }
        }

        private func text(_ part: Part) -> String? {
            if let text = texts[part.slot] { return text }
            guard built.contains(part.slot) else { return nil }
            let text = files.text(part)
            texts[part.slot] = text
            return text
        }

        private func bytes(_ part: Part) -> Int { text(part)?.utf8.count ?? 0 }

        /// Starts the nodes ready, in the order their messages came (at a tie, a merge first), while `jobs` run.
        private func pump() {
            guard failure == nil else { return }
            let next = ready.subtracting(busy).sorted { ($0.ctx, -$0.l) < ($1.ctx, -$1.l) }
            for part in next.prefix(max(0, Memory.jobs - busy.count)) {
                busy.insert(part)
                Task { await job(part) }
            }
        }

        private func job(_ part: Part) async {
            do {
                try store(part, await build(part))
            } catch {
                log.error("node \(part.l)/\(part.i): \(error)")
                failure = error.localizedDescription
            }
            busy.remove(part)
            fit(next: false)
            pump()
            waiters.forEach { $0.resume() }
            waiters = []
        }

        /// Node (l, i)'s line: its source if it fits, else asked of the model with the summaries' view up to it, up to
        /// `tries` times while too long, the shortest kept; no line (a refusal) is the source cut.
        private func build(_ part: Part) async throws -> String {
            let source: String
            if part.l == 0 {
                source = Memory.clip(try await message(part.i).map(Memory.show) ?? "", Memory.sourceLimit)
            } else {
                source = part.halves.map { Memory.flat(text($0) ?? "") }.joined(separator: "\n")
            }
            if source.utf8.count <= Memory.node { return source }
            let upto = min(part.ctx, leaves)
            let chat = "<chat>\n" + views.seen.parts.filter { $0.last < upto && built.contains($0.slot) }
                .map { "\($0.ref)|\(Memory.flat(text($0) ?? ""))" }.joined(separator: "\n") + "\n</chat>\n"
            let task = Memory.task(part) + source + "\n</input>"
            var lines: [String] = []
            var note: [ContentBlock] = []
            while lines.count < Memory.tries {
                let answer = try await models.complete(
                    summarizer,
                    context: ModelContext(
                        systemPrompt: Memory.compactor, messages: [.user(UserMessage(content: [.text(chat), .text(task)] + note))]),
                    options: ModelOptions(reasoning: .low))
                guard answer.stopReason != .error, answer.stopReason != .aborted else {
                    throw Failure(answer.errorMessage ?? "no answer")
                }
                let line = Memory.flat(answer.text).replacing(/^\d+\+\d+\|/, with: "")
                guard !line.isEmpty else { break }
                lines.append(line)
                if line.utf8.count <= Memory.node { break }
                note = [.text("\n" + Memory.over(line))]
            }
            return lines.min { $0.utf8.count < $1.utf8.count } ?? Memory.cut(Memory.flat(source))
        }

        private func store(_ part: Part, _ text: String) throws {
            try files.store(part, text)
            built.insert(part.slot)
            texts[part.slot] = text
            ready.remove(part)
            if built.contains(part.sibling.slot), !built.contains(part.parent.slot) { ready.insert(part.parent) }
            while built.contains(Part(l: 0, i: leaves).slot) { leaves += 1 }
        }

        // MARK: Views

        /// Each view to its end; a batch starts as a view passes its high, or goes on at a message (`next`) if a
        /// parent not built stopped it; between messages only a whole batch, to half or by the high: each change makes
        /// every request after write the view anew.
        private func fit(next: Bool) {
            var fitted = views
            fitted.view = fit(views.view, end: count, high: Memory.high, next: next)
            fitted.seen = fit(views.seen, end: leaves, high: Memory.seenHigh, next: next)
            guard fitted != views else { return }
            views = fitted
            let held = Set((views.view.parts + views.seen.parts).map(\.slot))
            texts = texts.filter { held.contains($0.key) }
            do {
                try files.save(views)
            } catch {
                log.error("views not kept: \(error)")
            }
        }

        private func fit(_ view: View, end: Int, high: Int, next: Bool) -> View {
            var view = view
            if view.end < end { view.parts += (view.end..<end).map { Part(l: 0, i: $0) } }
            let size = view.parts.reduce(0) { $0 + bytes($1) }
            guard size > high || (next && view.batch) else { return view }
            let merged = Memory.merge(view.parts, size: size, low: high / 2, built: { built.contains($0.slot) }, bytes: bytes)
            var now = size
            if next || merged.size <= max(high / 2, size - high) {
                view.parts = merged.parts
                now = merged.size
            }
            view.batch = now > high / 2
            return view
        }
    }
}
