import Foundation
import PiDurableKit

/// Mycroft's own code, agent and screen, as numbered generations on disk.
///
/// ```
/// Documents/agent/
///   state.json             active, last good, boot attempts, history
///   generations/<n>/       the files the agent changed, as of generation n — never edited once written
///   draft/                 the next generation, being edited by the agent
/// ```
///
/// The agent edits the draft, `promoteDraft` freezes it as generation n+1. A generation that keeps failing to boot
/// is rolled back to the last one that ran healthily. A generation holds only what the agent changed; every other
/// file is the app's own (its bundled generation 0), so an app update reaches every generation. See
/// docs/decisions/0004-self-modification-by-generations.md and 0009-self-editable-web-ui.md.
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
    /// The app's bundled generation 0: the source of files an older generation doesn't have.
    private(set) var bundled: URL?
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

    /// Starts the history the first time, with generation 0: the app's own files.
    func bootstrap(bundled: URL) throws {
        self.bundled = bundled
        defer { pruneInherited() }
        guard !fm.fileExists(atPath: folder(0).path) else { return }
        try fm.createDirectory(at: folder(0), withIntermediateDirectories: true)
        state = State(history: [Record(generation: 0, note: "Shipped with the app", createdAt: .now)])
        try save()
    }

    /// Generations used to hold full copies of the app's files, and an old copy hides the app's updates. Generation 0
    /// and the host files are always the app's, and a copy identical to the app's adds nothing: they go.
    private func pruneInherited() {
        guard let bundled else { return }
        let folders = ((try? fm.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil)) ?? []) + [draft]
        for folder in folders where fm.fileExists(atPath: folder.path) {
            let appsOwn = folder.standardizedFileURL == self.folder(0).standardizedFileURL
            for path in Self.files(in: folder) {
                let own = folder.appending(path: path)
                guard appsOwn || Self.hostFiles.contains(path)
                    || fm.contentsEqual(atPath: own.path, andPath: bundled.appending(path: path).path)
                else { continue }
                try? fm.removeItem(at: own)
            }
        }
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
        try extensionFor(generation: state.active)
    }

    func extensionFor(generation: Int) throws -> Extension {
        guard let url = Self.locate("extension.js", in: folder(generation), bundled: bundled) else {
            throw SelfError.unknownGeneration(generation)
        }
        return makeExtension(source: try String(contentsOf: url, encoding: .utf8), generation: generation)
    }

    func draftExtension() throws -> (Extension, generation: Int) {
        let url = draft.appending(path: "extension.js")
        guard fm.fileExists(atPath: url.path) else { throw SelfError.noDraft }
        let next = nextGeneration
        return (makeExtension(source: try String(contentsOf: url, encoding: .utf8), generation: next), next)
    }

    var nextGeneration: Int { (state.history.map(\.generation).max() ?? 0) + 1 }

    private func makeExtension(source: String, generation: Int) -> Extension {
        let prelude = "const MYCROFT = Object.freeze({ generation: \(generation), device: \"iPhone\" });\n"
        return Extension(Self.extensionName, javaScript: prelude + source,
                         sourceURL: URL(string: "mycroft://generation/\(generation)/extension.js"))
    }

    // MARK: Files

    /// Files that describe the app itself (its tools, the screen's data and ops). They change with the app, so every
    /// generation reads the app's copy, and the agent can't write them.
    nonisolated static let hostFiles: Set<String> = ["SELF.md", "ui/README.md"]

    /// Where a file of a generation folder really is: the folder's own copy, or the app's generation 0.
    nonisolated static func locate(_ path: String, in folder: URL, bundled: URL?) -> URL? {
        if hostFiles.contains(path), let host = bundled?.appending(path: path), FileManager.default.fileExists(atPath: host.path) {
            return host
        }
        let own = folder.appending(path: path)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        if let fallback = bundled?.appending(path: path), FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        return nil
    }

    /// The folder of a generation, or of the draft, for serving its screen.
    nonisolated static func folder(of generation: Int?, root: URL) -> URL {
        guard let generation else { return root.appending(path: "draft", directoryHint: .isDirectory) }
        return root.appending(path: "generations/\(generation)", directoryHint: .isDirectory)
    }

    /// Every file path of a generation folder, including the ones it inherits from generation 0.
    private func effectiveFiles(_ folder: URL) -> Set<String> {
        Self.files(in: folder).union(bundled.map(Self.files(in:)) ?? [])
    }

    private nonisolated static func files(in folder: URL) -> Set<String> {
        guard let paths = FileManager.default.subpaths(atPath: folder.path) else { return [] }
        return Set(paths.filter { path in
            var directory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appending(path: path).path, isDirectory: &directory)
            return !directory.boolValue && !path.hasSuffix(".DS_Store")
        })
    }

    private var workingFolder: URL { fm.fileExists(atPath: draft.path) ? draft : folder(state.active) }

    // MARK: Editing

    /// Reads a file of the draft (or of the active generation without one), or of pi-durable's bundled documentation
    /// under `docs/pi-durable/`.
    func read(_ path: String) throws -> String {
        let clean = try sanitize(path)
        if clean.hasPrefix("docs/pi-durable/") {
            let url = PiDurable.documentation.appending(path: "pi-durable/" + clean.dropFirst("docs/pi-durable/".count))
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard let url = Self.locate(clean, in: workingFolder, bundled: bundled) else { throw SelfError.notFound(clean) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func list() throws -> [String] {
        let docs = (try? fm.subpathsOfDirectory(atPath: PiDurable.documentation.appending(path: "pi-durable").path)) ?? []
        return effectiveFiles(workingFolder).sorted()
            + docs.filter { $0.hasSuffix(".md") || $0.hasSuffix(".d.ts") }.sorted().map { "docs/pi-durable/" + $0 }
    }

    /// Writes into the draft, creating it as a complete copy of the active generation first.
    func write(_ path: String, content: String) throws {
        let clean = try sanitize(path)
        guard !clean.hasPrefix("docs/"), !Self.hostFiles.contains(clean) else { throw SelfError.readOnly(clean) }
        try ensureDraft()
        let url = draft.appending(path: clean)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    var hasDraft: Bool { fm.fileExists(atPath: draft.path) }

    /// Starts the draft from the active generation: the files the agent changed so far.
    private func ensureDraft() throws {
        guard !fm.fileExists(atPath: draft.path) else { return }
        let active = folder(state.active)
        if fm.fileExists(atPath: active.path) {
            try fm.copyItem(at: active, to: draft)
        } else {
            try fm.createDirectory(at: draft, withIntermediateDirectories: true)
        }
    }

    func discardDraft() throws {
        if fm.fileExists(atPath: draft.path) { try fm.removeItem(at: draft) }
    }

    /// A line diff of the draft against the active generation.
    func diff() throws -> String {
        guard fm.fileExists(atPath: draft.path) else { return "No draft. Write a file with self_write first." }
        let active = folder(state.active)
        var out: [String] = []
        for name in changedFiles(from: active, to: draft) {
            out.append("--- generation \(state.active)/\(name)\n+++ draft/\(name)")
            let difference = text(name, in: draft).components(separatedBy: "\n")
                .difference(from: text(name, in: active).components(separatedBy: "\n"))
            for change in difference {
                switch change {
                case .remove(let offset, let line, _): out.append("-\(offset + 1): \(line)")
                case .insert(let offset, let line, _): out.append("+\(offset + 1): \(line)")
                }
            }
        }
        return out.isEmpty ? "The draft is identical to generation \(state.active)." : out.joined(separator: "\n")
    }

    /// The screen files (under `ui/`, given relative to it) that differ between two generations.
    func uiChanges(from old: Int, to new: Int) -> [String] {
        Self.uiPaths(changedFiles(from: folder(old), to: folder(new)))
    }

    /// The screen files the draft changes.
    func draftUIChanges() -> [String] {
        guard fm.fileExists(atPath: draft.path) else { return [] }
        return Self.uiPaths(changedFiles(from: folder(state.active), to: draft))
    }

    private static func uiPaths(_ paths: [String]) -> [String] {
        paths.filter { $0.hasPrefix("ui/") }.map { String($0.dropFirst(3)) }
    }

    private func changedFiles(from old: URL, to new: URL) -> [String] {
        effectiveFiles(old).union(effectiveFiles(new)).sorted().filter { name in
            let a = Self.locate(name, in: old, bundled: bundled).flatMap { try? Data(contentsOf: $0) }
            let b = Self.locate(name, in: new, bundled: bundled).flatMap { try? Data(contentsOf: $0) }
            return a != b
        }
    }

    private func text(_ name: String, in folder: URL) -> String {
        Self.locate(name, in: folder, bundled: bundled).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
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
        case .readOnly(let path): "\(path) is read-only: it documents the app and changes with it."
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
