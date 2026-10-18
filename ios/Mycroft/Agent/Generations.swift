import Foundation
import PiDurableKit

/// The agent's own code, as numbered generations on disk.
///
/// ```
/// Documents/agent/
///   state.json             active, last good, boot attempts, history
///   generations/<n>/       extension.js, SELF.md — never edited once written
///   draft/                 the next generation, being edited by the agent
/// ```
///
/// The agent edits the draft, `promoteDraft` freezes it as generation n+1. A generation that keeps failing to boot
/// is rolled back to the last one that ran healthily. See docs/decisions/0004-self-modification-by-generations.md.
actor GenerationStore {
    struct Record: Codable, Sendable, Hashable, Identifiable {
        var generation: Int
        var note: String
        var createdAt: Date
        var id: Int { generation }
    }

    struct State: Codable, Sendable {
        var active = 0
        var lastGood = 0
        var bootAttempts = 0
        var history: [Record] = []
    }

    static let extensionName = "mycroft"
    static let maxBootAttempts = 3

    let root: URL
    private(set) var state = State()
    /// The app's bundled generation 0: defaults for files an older generation doesn't have (appearance.json).
    private var bundled: URL?
    private let fm = FileManager.default

    init(root: URL = URL.documentsDirectory.appending(path: "agent", directoryHint: .isDirectory)) {
        self.root = root
        if let data = try? Data(contentsOf: root.appending(path: "state.json")),
            let stored = try? JSONDecoder.iso.decode(State.self, from: data)
        {
            state = stored
        }
    }

    private var generations: URL { root.appending(path: "generations", directoryHint: .isDirectory) }
    private var draft: URL { root.appending(path: "draft", directoryHint: .isDirectory) }
    private func folder(_ generation: Int) -> URL { generations.appending(path: "\(generation)", directoryHint: .isDirectory) }

    // MARK: Boot

    /// Installs generation 0 from the app bundle the first time.
    func bootstrap(bundled: URL) throws {
        self.bundled = bundled
        guard !fm.fileExists(atPath: folder(0).path) else { return }
        try fm.createDirectory(at: generations, withIntermediateDirectories: true)
        try fm.copyItem(at: bundled, to: folder(0))
        state = State(history: [Record(generation: 0, note: "Shipped with the app", createdAt: .now)])
        try save()
    }

    /// Counts a boot of the active generation. After too many boots that never became healthy, switches back to the
    /// last good generation and returns the generation it gave up on.
    func beginBoot() throws -> Int? {
        state.bootAttempts += 1
        var abandoned: Int?
        if state.bootAttempts > Self.maxBootAttempts, state.active != state.lastGood {
            abandoned = state.active
            state.active = state.lastGood
            state.bootAttempts = 1
        }
        try save()
        return abandoned
    }

    /// The active generation ran long enough to trust it.
    func markHealthy() throws {
        state.bootAttempts = 0
        state.lastGood = state.active
        try save()
    }

    /// Falls back to the last good generation right away, e.g. when the active one fails to load.
    func fallBack() throws -> Int {
        let failed = state.active
        state.active = state.lastGood
        state.bootAttempts = 0
        try save()
        return failed
    }

    // MARK: Loading

    func activeExtension() throws -> Extension {
        try makeExtension(source: try String(contentsOf: folder(state.active).appending(path: "extension.js"), encoding: .utf8),
                          generation: state.active)
    }

    func extensionFor(generation: Int) throws -> Extension {
        try makeExtension(source: try String(contentsOf: folder(generation).appending(path: "extension.js"), encoding: .utf8),
                          generation: generation)
    }

    func draftExtension() throws -> (Extension, generation: Int) {
        let url = draft.appending(path: "extension.js")
        guard fm.fileExists(atPath: url.path) else { throw SelfError.noDraft }
        let next = nextGeneration
        return (try makeExtension(source: try String(contentsOf: url, encoding: .utf8), generation: next), next)
    }

    var nextGeneration: Int { (state.history.map(\.generation).max() ?? 0) + 1 }

    private func makeExtension(source: String, generation: Int) throws -> Extension {
        let prelude = "const MYCROFT = Object.freeze({ generation: \(generation), device: \"iPhone\" });\n"
        return Extension(Self.extensionName, javaScript: prelude + source,
                         sourceURL: URL(string: "mycroft://generation/\(generation)/extension.js"))
    }

    // MARK: Editing

    /// Reads a file of the active generation, or of pi-durable's bundled documentation under `docs/pi-durable/`.
    func read(_ path: String) throws -> String {
        let clean = try sanitize(path)
        if clean.hasPrefix("docs/pi-durable/") {
            let url = PiDurable.documentation.appending(path: "pi-durable/" + clean.dropFirst("docs/pi-durable/".count))
            return try String(contentsOf: url, encoding: .utf8)
        }
        let base = fm.fileExists(atPath: draft.path) ? draft : folder(state.active)
        let url = base.appending(path: clean)
        if !fm.fileExists(atPath: url.path), let fallback = bundled?.appending(path: clean), fm.fileExists(atPath: fallback.path) {
            return try String(contentsOf: fallback, encoding: .utf8)  // e.g. appearance.json in an older generation
        }
        guard fm.fileExists(atPath: url.path) else { throw SelfError.notFound(clean) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The active generation's appearance.json, or the app's default.
    func appearance() -> Data? {
        let own = folder(state.active).appending(path: "appearance.json")
        if let data = try? Data(contentsOf: own) { return data }
        return bundled.flatMap { try? Data(contentsOf: $0.appending(path: "appearance.json")) }
    }

    /// A file of the draft, if the draft has one.
    func draftFile(_ name: String) -> Data? {
        try? Data(contentsOf: draft.appending(path: name))
    }

    func list() throws -> [String] {
        let base = fm.fileExists(atPath: draft.path) ? draft : folder(state.active)
        let own = Array(Set(((try? fm.contentsOfDirectory(atPath: base.path)) ?? []) + ["appearance.json"]))
        let docs = (try? fm.subpathsOfDirectory(atPath: PiDurable.documentation.appending(path: "pi-durable").path)) ?? []
        return own.sorted() + docs.filter { $0.hasSuffix(".md") || $0.hasSuffix(".d.ts") }.sorted().map { "docs/pi-durable/" + $0 }
    }

    /// Writes into the draft, creating it as a copy of the active generation first.
    func write(_ path: String, content: String) throws {
        let clean = try sanitize(path)
        guard !clean.hasPrefix("docs/") else { throw SelfError.readOnly(clean) }
        if !fm.fileExists(atPath: draft.path) {
            try fm.copyItem(at: folder(state.active), to: draft)
        }
        let url = draft.appending(path: clean)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    func discardDraft() throws {
        if fm.fileExists(atPath: draft.path) { try fm.removeItem(at: draft) }
    }

    /// A line diff of the draft against the active generation.
    func diff() throws -> String {
        guard fm.fileExists(atPath: draft.path) else { return "No draft. Write a file with self_write first." }
        let active = folder(state.active)
        let names = Set((try fm.contentsOfDirectory(atPath: draft.path)) + (try fm.contentsOfDirectory(atPath: active.path)))
        var out: [String] = []
        for name in names.sorted() {
            let old = (try? String(contentsOf: active.appending(path: name), encoding: .utf8)) ?? ""
            let new = (try? String(contentsOf: draft.appending(path: name), encoding: .utf8)) ?? ""
            guard old != new else { continue }
            out.append("--- generation \(state.active)/\(name)\n+++ draft/\(name)")
            let difference = new.components(separatedBy: "\n").difference(from: old.components(separatedBy: "\n"))
            for change in difference {
                switch change {
                case .remove(let offset, let line, _): out.append("-\(offset + 1): \(line)")
                case .insert(let offset, let line, _): out.append("+\(offset + 1): \(line)")
                }
            }
        }
        return out.isEmpty ? "The draft is identical to generation \(state.active)." : out.joined(separator: "\n")
    }

    /// Freezes the draft as the next generation and makes it active.
    func promoteDraft(note: String) throws -> Int {
        guard fm.fileExists(atPath: draft.path) else { throw SelfError.noDraft }
        let next = nextGeneration
        try fm.moveItem(at: draft, to: folder(next))
        state.history.append(Record(generation: next, note: note, createdAt: .now))
        state.active = next
        state.bootAttempts = 0
        try save()
        return next
    }

    func activate(_ generation: Int) throws {
        guard fm.fileExists(atPath: folder(generation).path) else { throw SelfError.unknownGeneration(generation) }
        state.active = generation
        state.bootAttempts = 0
        try save()
    }

    // MARK: Persistence

    private func save() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(state).write(to: root.appending(path: "state.json"), options: .atomic)
    }

    private func sanitize(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty, !trimmed.split(separator: "/").contains(".."), !trimmed.contains("\0") else {
            throw SelfError.badPath(path)
        }
        return trimmed
    }
}

nonisolated enum SelfError: LocalizedError {
    case noDraft, notFound(String), readOnly(String), badPath(String), unknownGeneration(Int)

    var errorDescription: String? {
        switch self {
        case .noDraft: "There is no draft. Use self_write to start one."
        case .notFound(let path): "No such file: \(path)"
        case .readOnly(let path): "\(path) is read-only documentation."
        case .badPath(let path): "Invalid path: \(path)"
        case .unknownGeneration(let generation): "There is no generation \(generation)."
        }
    }
}

extension JSONEncoder {
    nonisolated static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    nonisolated static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
