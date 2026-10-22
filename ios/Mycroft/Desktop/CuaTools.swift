import Foundation
import os
import PiDurableKit

/// Desktop control on paired Macs: Cua Driver's own tools, carried as-is by `hands` (`cua.tools`, `cua.call`).
///
/// The catalog (Cua's MCP tool list and server instructions) is bundled, and cached anew when a Mac connects with a newer
/// Cua Driver; a new catalog takes effect the next time the harness opens. Every tool takes `machine`. Actions that look
/// irreversible stop for the user first: the model repeats the call with `confirmed: true` once they agree.
nonisolated enum CuaTools {
    /// Always offered to the model, Cua's own loop: find or open the window, read it, act on it. The rest of the catalog
    /// waits for tool_search: the single actions (click, type_text, …) are run_steps' steps, and its `expect` and
    /// `observe` check and read what changed. Every tool here costs each request its schema (these four, about 21 KB).
    static let core: Set<String> = ["list_windows", "launch_app", "get_window_state", "run_steps"]

    /// Not offered at all: Mycroft ships neither Cua's perception model nor Computer History.
    static func isExcluded(_ name: String) -> Bool {
        name == "parse_visual_regions" || name.hasPrefix("history_")
    }

    /// Words that make an action irreversible enough to ask the user first.
    static let destructive = ["delete", "remove", "erase", "trash", "send", "post", "pay", "buy", "purchase", "order", "transfer", "sign out", "log out", "quit", "shut down", "restart", "format"]

    /// Tools Cua marks destructive because any input may be: they are judged by what they target and type instead.
    static let judgedByTarget: Set<String> = [
        "click", "double_click", "right_click", "drag", "scroll", "move_cursor", "type_text", "type_text_chars", "press_key",
        "hotkey", "set_value", "invoke_menu", "run_steps", "run_script",
    ]

    private static let log = Logger(subsystem: "dev.mycroft", category: "cua")

    // MARK: Catalog

    /// Cua Driver's `cua.tools` result: MCP `tools/list` entries and the server's instructions.
    struct Catalog: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            struct Annotations: Decodable, Sendable {
                var readOnlyHint: Bool?
                var destructiveHint: Bool?
            }
            var name: String
            var description: String?
            var inputSchema: JSONValue?
            var annotations: Annotations?

            var isReadOnly: Bool { annotations?.readOnlyHint == true }
            var isDestructive: Bool { annotations?.destructiveHint == true }
        }
        var version: String
        var instructions: String?
        var tools: [Entry]

        static var cached: URL { URL.applicationSupportDirectory.appending(path: "cua-tools.json") }
        static var bundled: URL? { Bundle.main.url(forResource: "cua-tools", withExtension: "json") }

        static func decode(_ data: Data) throws -> Catalog { try JSONDecoder().decode(Catalog.self, from: data) }

        /// The newer of the bundled and the cached catalog (the bundled one on a tie).
        static func load(cached: URL = Catalog.cached, bundled: URL? = Catalog.bundled) -> Catalog? {
            [bundled, cached].compactMap { $0 }.compactMap { try? decode(Data(contentsOf: $0)) }
                .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        }
    }

    /// Versions being fetched or fetched in this process.
    private static let fetched = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Called when a machine connects: if it runs a newer Cua Driver than the catalog, caches its catalog.
    static func refreshCatalog(from hands: HandsConnection, cached: URL = Catalog.cached) async {
        guard let info = await hands.info, (info["features"] as? [String])?.contains("cua.tools") == true,
            let version = (info["cua"] as? [String: Any])?["version"] as? String,
            version.compare(Catalog.load(cached: cached)?.version ?? "0", options: .numeric) == .orderedDescending,
            fetched.withLock({ $0.insert(version).inserted })
        else { return }
        do {
            let reply = try await hands.request("cua.tools")
            let data = try JSONSerialization.data(withJSONObject: reply.json)
            _ = try Catalog.decode(data)
            try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cached, options: .atomic)
            log.info("cached Cua Driver \(version)'s tools; they load with the next harness")
        } catch {
            fetched.withLock { _ = $0.remove(version) }
            log.error("fetching Cua Driver \(version)'s tools failed: \(error)")
        }
    }

    // MARK: Extension

    static func makeExtension(catalog: Catalog? = Catalog.load()) -> Extension {
        let entries = (catalog?.tools ?? []).filter { !isExcluded($0.name) }
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return Extension(
            "mycroft.cua",
            tools: entries.map(tool),
            sections: catalog.map { [PromptSection("desktop", text: prompt($0))] } ?? [],
            hooks: [Hook.beforeTool { call, _ in await confirm(call, catalog: byName) }])
    }

    static func prompt(_ catalog: Catalog) -> String {
        let mycroft = "These desktop tools (Cua Driver) drive the apps of a paired Mac in the background; each takes `machine`. Act with run_steps, even for one action: its steps are the action tools, with their own arguments. The other desktop tools load with tool_search. For shell work, use the hands_* command tools."
        return [mycroft, catalog.instructions].compactMap { $0 }.joined(separator: "\n\n")
    }

    static func tool(_ entry: Catalog.Entry) -> Tool {
        let tool = Tool(
            entry.name, description: entry.description ?? entry.name, parameters: parameters(entry),
            replay: entry.isReadOnly ? .safe : .unsafe
        ) { (args: JSONValue, call) -> ToolResult in
            var arguments = args.objectValue ?? [:]
            let name = arguments.removeValue(forKey: "machine")?.stringValue ?? ""
            arguments["confirmed"] = nil
            let machine = try await HandsTools.resolve(name, call)
            let result = try await perform(entry, arguments, on: machine, within: limit)
            await CuaSnapshots.shared.record(result, machine: machine.name)
            return toolResult(result)
        }
        return core.contains(entry.name) ? tool : tool.deferringUntilLoaded()
    }

    /// The tool's own schema, plus the machine and, for tools that act, the user's confirmation.
    static func parameters(_ entry: Catalog.Entry) -> JSONSchema {
        var schema = entry.inputSchema?.objectValue ?? [:]
        schema["type"] = "object"
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["machine"] = ["type": "string", "description": "Machine name (a paired Mac)"]
        if !entry.isReadOnly {
            properties["confirmed"] = ["type": "boolean", "description": "Set only after the user approved this exact action"]
        }
        schema["properties"] = .object(properties)
        schema["required"] = .array(["machine"] + (schema["required"]?.arrayValue ?? []).filter { $0 != "machine" })
        return JSONSchema(schema)
    }

    /// The longest a desktop call may take. Cua bounds its own waits (a run_steps step waits 10 s at most), so a call
    /// still going after this is stuck: it is cancelled on the Mac, and the model told.
    static let limit: Duration = .seconds(120)

    /// `perform`, cancelled after `limit`.
    static func perform(
        _ entry: Catalog.Entry, _ arguments: JSONObject, on machine: Machine, within limit: Duration
    ) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask { try await perform(entry, arguments, on: machine) }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() ?? nil else {
                let action = entry.isReadOnly ? "" : " Part of it may have happened: read the window before trying again."
                throw ToolError("\(entry.name) on \(machine.name) took longer than \(limit.components.seconds) s and was stopped.\(action)")
            }
            return result
        }
    }

    static func perform(_ entry: Catalog.Entry, _ arguments: JSONObject, on machine: Machine) async throws -> JSONValue {
        let send: @Sendable (HandsConnection) async throws -> JSONValue = { hands in
            guard machine.os == "macos", (await hands.info?["features"] as? [String])?.contains("cua.call") == true else {
                throw ToolError("Desktop control works on paired Macs with an up-to-date hands; \(machine.name) has none. Update hands there (Settings → Machines) or use a Mac.")
            }
            let fields: [String: Any] = ["name": entry.name, "arguments": try foundation(.object(arguments))]
            return try json(try await hands.request("cua.call", fields).json)
        }
        // A connection lost mid-call may have delivered the action already, so only reads retry on a fresh one.
        if entry.isReadOnly { return try await HandsPool.shared.with(machine, send) }
        return try await send(try await HandsPool.shared.connection(to: machine))
    }

    /// An MCP CallToolResult as the model's result: text and images; the structured content only when there is no text.
    static func toolResult(_ result: JSONValue) -> ToolResult {
        var output: [ContentBlock] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue { output.append(.text(text)) }
            case "image":
                if let data = block["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) {
                    output.append(.image(ImageContent(data: data, mimeType: block["mimeType"]?.stringValue ?? "image/png")))
                }
            default:
                break
            }
        }
        let isError = result["isError"]?.boolValue ?? false
        if !output.contains(where: { $0.text != nil }), let structured = result["structuredContent"], !structured.isNull {
            output.append(.text(structured.jsonString))
        }
        if output.isEmpty { output = [.text(isError ? "Failed." : "Done.")] }
        return ToolResult(output: output, isError: isError)
    }

    static func json(_ object: [String: Any]) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func foundation(_ value: JSONValue) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }

    // MARK: Confirmation

    struct Risk: Equatable {
        /// What was about to happen: "clicking “Send” in Mail".
        var action: String
        /// Why it looks irreversible: "“send”".
        var reason: String
    }

    /// Stops an action that looks irreversible until the user approved it; strips `confirmed` before it reaches Cua.
    static func confirm(_ call: ToolCall, catalog: [String: Catalog.Entry]) async -> ToolDecision {
        guard let entry = catalog[call.name], !entry.isReadOnly else { return .allow }
        var arguments = call.arguments
        let confirmed = arguments.removeValue(forKey: "confirmed")
        if confirmed?.boolValue == true { return .rewrite(arguments) }
        let index = await CuaSnapshots.shared.index(arguments["machine"]?.stringValue ?? "")
        if let risk = risk(entry, arguments: arguments, index: index, catalog: catalog) {
            return .block("Stopped before \(risk.action): it looks irreversible (\(risk.reason)). Ask the user; if they agree, call \(entry.name) again with the same arguments and confirmed: true.")
        }
        return confirmed == nil ? .allow : .rewrite(arguments)
    }

    /// Why this call needs the user's confirmation, or nil. A target the index doesn't know is no reason.
    static func risk(_ entry: Catalog.Entry, arguments: JSONObject, index: SnapshotIndex, catalog: [String: Catalog.Entry] = [:]) -> Risk? {
        var found = Walk()
        found.visit(.object(arguments), tool: entry.name, catalog: catalog)
        let targets = found.tokens.compactMap { token in index.target(token.token).map { (tool: token.tool, target: $0) } }

        if let keys = found.keys.first(where: isRiskyCombination) {
            let combination = keys.joined(separator: "+")
            return Risk(action: "pressing \(combination)", reason: "“\(combination)”")
        }
        for (tool, target) in targets {
            if let word = destructiveWord(in: target.row.words) {
                return Risk(action: describe(tool, [:], target: target), reason: "“\(word)”")
            }
        }
        let action = describe(entry.name, arguments, target: targets.first?.target)
        if let word = found.texts.lazy.compactMap(destructiveWord).first {
            return Risk(action: action, reason: "“\(word)”")
        }
        for name in [entry.name] + found.tools.sorted() {
            guard let tool = name == entry.name ? entry : catalog[name], tool.isDestructive, !judgedByTarget.contains(name) else { continue }
            return Risk(action: name == entry.name ? action : "calling \(name)", reason: "Cua marks \(name) destructive")
        }
        return nil
    }

    /// What an argument tree holds: the text it would type or choose, the elements it targets, the keys it presses.
    struct Walk {
        var texts: [String] = []
        var tokens: [(tool: String, token: String)] = []
        var keys: [[String]] = []
        /// Tools named inside it (run_steps steps).
        var tools: Set<String> = []

        /// Keys whose strings name no target: metadata, key names (judged as combinations) and reads.
        static let skipped: Set<String> = [
            "machine", "confirmed", "session", "tool", "key", "keys", "modifiers", "modifier", "delivery_mode", "scope",
            "capture_id", "observe", "expect", "wait_for",
        ]

        mutating func visit(_ value: JSONValue, tool: String, catalog: [String: Catalog.Entry]) {
            switch value {
            case .string(let text):
                texts.append(text)
            case .array(let items):
                for item in items { visit(item, tool: tool, catalog: catalog) }
            case .object(let object):
                let tool = object["tool"]?.stringValue ?? tool
                if object["tool"] != nil { tools.insert(tool) }
                if let combination = Self.combination(object) { keys.append(combination) }
                for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                    if key == "element_token", let token = child.stringValue {
                        tokens.append((tool, token))
                    } else if !Self.skipped.contains(key) {
                        // `{"click": {…}}`: a step written as its tool's name.
                        let named = catalog[key] != nil || CuaTools.verbs[key] != nil
                        if named { tools.insert(key) }
                        visit(child, tool: named ? key : tool, catalog: catalog)
                    }
                }
            default:
                break
            }
        }

        /// The keys a press_key or hotkey object presses, normalized: ["shift", "cmd", "delete"].
        static func combination(_ object: JSONObject) -> [String]? {
            var parts = object["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let key = object["key"]?.stringValue { parts.append(key) }
            guard !parts.isEmpty else { return nil }
            for name in ["modifiers", "modifier"] {
                parts = (object[name]?.arrayValue?.compactMap(\.stringValue) ?? object[name]?.stringValue.map { [$0] } ?? []) + parts
            }
            return parts.flatMap { $0.split(separator: "+") }.map { part in
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "command", "⌘", "meta", "super": "cmd"
                case "backspace", "forwarddelete", "forward_delete", "del", "⌫": "delete"
                case "option", "opt", "⌥": "alt"
                case "control", "⌃": "ctrl"
                case let other: other
                }
            }
        }
    }

    /// Quits or deletes: cmd+q, cmd+delete (backspace), shift+cmd+delete.
    static func isRiskyCombination(_ keys: [String]) -> Bool {
        keys.contains("cmd") && (keys.contains("q") || keys.contains("delete"))
    }

    static func destructiveWord(in text: String) -> String? {
        destructive.first { word in
            let pattern = "\\b" + word.replacingOccurrences(of: " ", with: "\\s+") + "\\b"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static let verbs = [
        "click": "clicking", "double_click": "double-clicking", "right_click": "right-clicking", "drag": "dragging",
        "type_text": "typing into", "type_text_chars": "typing into", "set_value": "setting", "press_key": "pressing a key in",
        "hotkey": "pressing keys in", "scroll": "scrolling",
    ]

    /// A short description of an action for the user: "clicking “Send” in Mail", "typing “Hi” into “To”".
    static func describe(_ tool: String, _ arguments: JSONObject, target: SnapshotIndex.Target?) -> String {
        let place = target?.app.map { " in \($0)" } ?? ""
        let element = target.map { "“\(clip($0.row.name))”\(place)" }
        switch tool {
        case "type_text", "type_text_chars":
            guard let text = arguments["text"]?.stringValue else { break }
            return "typing “\(clip(text))”" + (element.map { " into \($0)" } ?? "")
        case "press_key", "hotkey":
            guard let keys = Walk.combination(arguments) else { break }
            return "pressing \(keys.joined(separator: "+"))"
        case "invoke_menu":
            let path = arguments["path"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " > ") ?? arguments["path"]?.stringValue
            guard let path else { break }
            return "choosing \(path)\(place)"
        case "run_steps":
            return "running these steps"
        case "run_script":
            return "running this script"
        default:
            break
        }
        if let verb = verbs[tool] { return element.map { "\(verb) \($0)" } ?? "\(verb.split(separator: " ")[0]) there" }
        return "calling \(tool)"
    }

    static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

// MARK: Snapshots

/// The rows of a machine's recent `get_window_state` reads, so an `element_token` (`<snapshot_id>:N`) can be named:
/// full reads, and diffs (`since`) merged into the snapshot they were taken against.
nonisolated struct SnapshotIndex: Sendable {
    struct Row: Sendable, Hashable {
        var role: String
        var title: String?
        var detail: String?

        var name: String { title ?? detail ?? role }
        /// What the element says, for destructive words; not its value, which is the user's content.
        var words: String { [title, detail].compactMap { $0 }.joined(separator: " ") }

        /// A tree row after its `[N] `: `AXButton "Send" = "value" (description) [id=… actions=[…]]`.
        init(_ text: some StringProtocol) {
            let match = String(text).prefixMatch(of: #/(\S+)(?: "((?:[^"\\]|\\.)*)")?(?: = "(?:[^"\\]|\\.)*")?(?: \(([^)]*)\))?/#)
            role = match.map { String($0.1) } ?? ""
            title = match?.2.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            detail = match?.3.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        }

        init(role: String, title: String?, detail: String?) {
            self.role = role
            self.title = title?.isEmpty == true ? nil : title
            self.detail = detail?.isEmpty == true ? nil : detail
        }
    }

    struct Snapshot: Sendable {
        var rows: [Int: Row]
        var app: String?
    }

    struct Target: Sendable {
        var row: Row
        var app: String?
    }

    static let limit = 24
    private(set) var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []

    func target(_ token: String) -> Target? {
        guard let colon = token.lastIndex(of: ":"), let row = Int(token[token.index(after: colon)...]),
            let snapshot = snapshots[String(token[..<colon])], let found = snapshot.rows[row]
        else { return nil }
        return Target(row: found, app: snapshot.app)
    }

    /// Indexes a tool result that carries a snapshot: get_window_state's, or run_steps' end read (`observation.state`).
    mutating func record(_ result: JSONValue) {
        let structured = result["structuredContent"]
        let state = structured?["observation"]?["state"] ?? structured
        let text = (result["content"]?.arrayValue ?? []).filter { $0["type"] == "text" }.compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
        guard let id = state?["snapshot_id"]?.stringValue ?? text.firstMatch(of: #/snapshot_id=(s[0-9a-f]+)/#).map({ String($0.1) })
        else { return }
        let header = text.firstMatch(of: #/^(?:no change )?since (s[0-9a-f]+)[:;.]/#.anchorsMatchLineEndings())
        let since = state?["since"]?.stringValue ?? header.map { String($0.1) }
        let isDiff = state?["since_status"]?.stringValue.map { $0 == "diff" || $0 == "no_change" } ?? (header != nil)
        let base = since.flatMap { snapshots[$0] }

        var rows: [Int: Row] = [:]
        if isDiff {
            var removed: Set<Int> = []
            var shifts: [(range: ClosedRange<Int>, delta: Int)] = []
            var current: [Int: Row] = [:]
            for line in (state?["tree_diff"]?.stringValue ?? text).split(separator: "\n") {
                if let row = line.wholeMatch(of: #/([+~-]) \[(\d+)\] (.*)/#), let index = Int(row.2) {
                    if row.1 == "-" { removed.insert(index) } else { current[index] = Row(row.3) }
                } else if let shift = line.wholeMatch(of: #/reindexed: \[(\d+)-(\d+)\] -> \[(-?\d+)-(-?\d+)\]/#),
                    let first = Int(shift.1), let last = Int(shift.2), let moved = Int(shift.3), first <= last
                {
                    shifts.append((first...last, moved - first))
                }
            }
            // Rows not listed keep their index unless a reindexed range moved them; removed ids are the old snapshot's.
            for (index, row) in base?.rows ?? [:] where !removed.contains(index) {
                rows[index + (shifts.first { $0.range.contains(index) }?.delta ?? 0)] = row
            }
            rows.merge(current) { _, new in new }
        } else {
            for line in (state?["tree_markdown"]?.stringValue ?? text).split(separator: "\n") {
                if let row = line.wholeMatch(of: #/\s*- \[(\d+)\] (.*)/#), let index = Int(row.1) { rows[index] = Row(row.2) }
            }
        }
        for element in state?["elements"]?.arrayValue ?? [] {
            guard let index = element["element_index"]?.intValue else { continue }
            rows[index] = Row(
                role: element["role"]?.stringValue ?? "",
                title: element["label"]?.stringValue ?? element["title"]?.stringValue,
                detail: element["description"]?.stringValue)
        }

        snapshots[id] = Snapshot(rows: rows, app: state?["app_name"]?.stringValue ?? base?.app)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.limit { snapshots[order.removeFirst()] = nil }
    }
}

/// Each machine's ``SnapshotIndex``, fed by the Cua tools' results and read by the confirmation hook.
actor CuaSnapshots {
    static let shared = CuaSnapshots()
    private var machines: [String: SnapshotIndex] = [:]

    func record(_ result: JSONValue, machine: String) {
        machines[machine.lowercased(), default: SnapshotIndex()].record(result)
    }

    func index(_ machine: String) -> SnapshotIndex {
        machines[machine.lowercased()] ?? SnapshotIndex()
    }
}
