import Foundation
import PiDurableKit

/// Desktop control on paired Macs (docs/desktop-protocol.md): `desktop_do` runs the observe → Jev → act → check
/// loop for a goal; `ui_observe` and `ui_act` let the model drive the Accessibility tree itself.
nonisolated enum DesktopTools {
    struct DoArguments: Decodable, Sendable {
        var machine: String
        var goal: String
        var max_steps: Int?
    }

    struct ObserveArguments: Decodable, Sendable {
        var machine: String
        var app: String?
    }

    struct ActArguments: Decodable, Sendable {
        var machine: String
        var observation: String
        var operation: String
        var ref: String?
        var text: String?
        var app: String?
        var url: String?
        var path: String?
        var key: String?
        var modifiers: [String]?
        var times: Int?
        var direction: String?
        var menu: String?
    }

    /// Words in a target that make an action destructive; desktop_do stops and asks instead.
    static let destructive = ["delete", "remove", "erase", "trash", "send", "post", "pay", "buy", "purchase", "order", "transfer", "sign out", "log out", "quit", "shut down", "restart", "format"]

    static func makeExtension() -> Extension {
        Extension("mycroft.desktop") {
            Tool(
                "desktop_do",
                description: "Do something in the apps on a paired Mac by operating its user interface, step by step (Jev reads the accessibility tree and picks each action). Use for GUI tasks: 'open Notes and create a note saying hello', 'in Safari open github.com'. Stops and returns early when a step needs the user's confirmation.",
                parameters: .object([
                    "machine": .string("Machine name (a Mac)"),
                    "goal": .string("What should be done, in plain words, including any exact text to type"),
                    "max_steps": .integer("Step limit (default 20)").optional,
                ])
            ) { (args: DoArguments, call) -> ToolResult in
                guard let apiKey = Keychain.read(Secret.jev) else {
                    throw ToolError("Desktop control needs a Jev API key: Settings → Desktop control.")
                }
                let machine = try await HandsTools.resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    try await run(goal: args.goal, maxSteps: args.max_steps ?? 20, on: hands, machine: machine, apiKey: apiKey, call: call)
                }
            }

            Tool(
                "ui_observe",
                description: "Read the user interface of an app on a paired Mac (the frontmost app by default): its controls with refs, values and supported operations, plus the apps, folders and menu items available.",
                parameters: .object(["machine": .string("Machine name"), "app": .string("App name or bundle id").optional]),
                replay: .safe
            ) { (args: ObserveArguments, call) -> String in
                let machine = try await HandsTools.resolve(args.machine, call)
                let reply = try await HandsPool.shared.with(machine) { hands in
                    var fields: [String: Any] = [:]
                    if let app = args.app { fields["app"] = app }
                    return try await hands.request("ui.observe", fields)
                }
                return describe(Observation(reply.json))
            }

            Tool(
                "ui_screenshot",
                description: "See the screen of a paired Mac: returns a screenshot of its main display. Use it when the accessibility tree from ui_observe is not enough (canvas apps, images, layout questions) or to check a result visually.",
                parameters: .object(["machine": .string("Machine name")]),
                replay: .safe
            ) { (args: ObserveArguments, call) -> ToolResult in
                let machine = try await HandsTools.resolve(args.machine, call)
                let reply = try await HandsPool.shared.with(machine) { try await $0.request("ui.screenshot", ["maxWidth": 1600]) }
                guard !reply.payload.isEmpty else { throw ToolError("\(machine.name) returned no screenshot") }
                let size = "\(reply.int("width") ?? 0)×\(reply.int("height") ?? 0)"
                return ToolResult(output: [.text("Screenshot of \(machine.name)'s main display (\(size))."),
                                           .image(ImageContent(data: reply.payload, mimeType: "image/png"))])
            }

            Tool(
                "ui_act",
                description: "Perform one user-interface operation on a paired Mac, using refs from the latest ui_observe. Operations: OPEN_APP{app}, QUIT_APP{app}, OPEN_URL{url}, OPEN_FOLDER{path}, PRESS{ref}, SELECT{ref}, CLICK{ref}, FOCUS{ref}, TYPE_TEXT{text, ref?}, PRESS_KEY{key, modifiers?, times?}, SCROLL{direction, times?}, MENU{menu}.",
                parameters: .object([
                    "machine": .string("Machine name"),
                    "observation": .string("The observation id from ui_observe"),
                    "operation": .string("Operation name"),
                    "ref": .string().optional, "text": .string().optional, "app": .string().optional,
                    "url": .string().optional, "path": .string().optional, "key": .string().optional,
                    "modifiers": .array(of: .string()).optional, "times": .integer().optional,
                    "direction": .string(enum: ["up", "down"]).optional, "menu": .string().optional,
                ])
            ) { (args: ActArguments, call) -> String in
                let machine = try await HandsTools.resolve(args.machine, call)
                var fields: [String: Any] = ["observation": args.observation, "operation": args.operation]
                for (key, value) in [("ref", args.ref), ("text", args.text), ("app", args.app), ("url", args.url), ("path", args.path),
                                     ("key", args.key), ("direction", args.direction), ("menu", args.menu)] {
                    if let value { fields[key] = value }
                }
                if let modifiers = args.modifiers { fields["modifiers"] = modifiers }
                if let times = args.times { fields["times"] = times }
                let request = UncheckedSendable(fields)  // plain JSON values
                let reply = try await HandsPool.shared.with(machine) { try await $0.request("ui.act", request.value) }
                let changed = reply.bool("screenChanged") ? "" : " (the screen did not change)"
                return (reply.string("result") ?? "Done") + changed
            }
        }
    }

    // MARK: The loop

    static func run(goal: String, maxSteps: Int, on hands: HandsConnection, machine: Machine, apiKey: String, call: ToolCallContext) async throws -> ToolResult {
        var recent: [JevClient.RecentAction] = []
        var log: [String] = []
        let words = goal.split(whereSeparator: \.isWhitespace).map(String.init)
        for step in 1...max(1, maxSteps) {
            try Task.checkCancellation()
            let observation = Observation(try await hands.request("ui.observe").json)
            let (state, operations, heads) = cycleInput(goal: goal, words: words, observation: observation, recent: recent)
            let decision = try await JevClient.cycle(state: state, operations: operations, heads: heads, apiKey: apiKey)
            guard let operation = decision.choice("operation") else { throw ToolError("Jev gave no operation") }

            switch operation.id {
            case "DONE":
                log.append("Done: the screen shows the goal is complete.")
                return finish(log, machine: machine, success: true)
            case "BLOCKED":
                log.append("Blocked: no available action makes progress in \(observation.application).")
                return finish(log, machine: machine, success: false)
            case "WAIT":
                recent.append(.init(action: "WAIT", result: "waited for the screen", screenChanged: false))
                try await Task.sleep(for: .seconds(1))
                continue
            default:
                break
            }

            guard let act = action(for: operation.id, decision: decision, observation: observation, words: words) else {
                recent.append(.init(action: operation.id, result: "no valid target was chosen", screenChanged: false))
                continue
            }
            if operation.confidence < 0.35 {
                log.append("Stopped before \(act.description): Jev is unsure (confidence \(Int(operation.confidence * 100))%).")
                return finish(log, machine: machine, success: false, ask: true)
            }
            if let word = destructive.first(where: { act.description.lowercased().contains($0) }) {
                log.append("Stopped before \(act.description): it looks irreversible (“\(word)”). Ask the user, then call ui_act yourself if they agree.")
                return finish(log, machine: machine, success: false, ask: true)
            }

            let description = act.description
            var fields = act.fields
            fields["observation"] = observation.id
            fields["operation"] = act.operation
            let reply = try await hands.request("ui.act", fields)
            let result = reply.string("result") ?? description
            let changed = reply.bool("screenChanged")
            recent.append(.init(action: description, result: result, screenChanged: changed))
            if recent.count > 10 { recent.removeFirst(recent.count - 10) }
            let line = String(format: "%02d ", step) + result + (changed ? "" : " (no visible change)")
            log.append(line)
            call.output(line + "\n")
            if decision.noul("finishes") >= 0.85 && changed {
                log.append("Done: Jev judged that step completed the goal.")
                return finish(log, machine: machine, success: true)
            }
        }
        log.append("Stopped after \(maxSteps) steps without reaching the goal.")
        return finish(log, machine: machine, success: false)
    }

    static func finish(_ log: [String], machine: Machine, success: Bool, ask: Bool = false) -> ToolResult {
        let header = success ? "Finished on \(machine.name)." : ask ? "Paused on \(machine.name): needs the user." : "Did not finish on \(machine.name)."
        return ToolResult(output: [.text(([header] + log).joined(separator: "\n"))], isError: !success && !ask)
    }

    // MARK: Jev input

    struct Observation {
        struct Element {
            let ref: String
            let index: Int
            let role: String
            let label: String
            let value: String?
            let place: String?
            let operations: [String]
        }
        let id: String
        let application: String
        let window: String
        let otherWindows: Int?
        let elements: [Element]
        let apps: [String]
        let folders: [String]
        let sites: [String]
        let menus: [String]

        init(_ json: [String: Any]) {
            id = json["observation"] as? String ?? ""
            application = json["application"] as? String ?? ""
            window = json["window"] as? String ?? ""
            otherWindows = (json["otherWindows"] as? NSNumber)?.intValue
            elements = ((json["elements"] as? [[String: Any]]) ?? []).map { element in
                Element(ref: element["ref"] as? String ?? "", index: (element["index"] as? NSNumber)?.intValue ?? 0,
                        role: element["role"] as? String ?? "", label: element["label"] as? String ?? "",
                        value: element["value"] as? String, place: element["place"] as? String,
                        operations: element["operations"] as? [String] ?? [])
            }
            let available = json["available"] as? [String: Any] ?? [:]
            apps = available["apps"] as? [String] ?? []
            folders = available["folders"] as? [String] ?? []
            sites = available["sites"] as? [String] ?? []
            menus = available["menus"] as? [String] ?? []
        }
    }

    struct Action {
        let operation: String
        let fields: [String: Any]
        let description: String
    }

    static func cycleInput(goal: String, words: [String], observation: Observation, recent: [JevClient.RecentAction])
        -> (JevClient.CycleState, [String: String], [String: [String: String]])
    {
        let elements = observation.elements.prefix(JevClient.maxOptions)
        let sites = observation.sites + sitesMentioned(in: goal)
        let state = JevClient.CycleState(
            goal: goal, dictation: nil, application: observation.application, window: observation.window,
            elements: elements.map { .init(index: $0.index, role: $0.role, label: $0.label, value: $0.value, place: $0.place, operations: $0.operations) },
            available: .init(apps: observation.apps, folders: observation.folders, sites: sites, menus: observation.menus),
            recentActions: recent, previous: nil, otherWindows: observation.otherWindows)

        func describe(_ element: Observation.Element) -> String {
            var text = "\(element.index). \(element.role) “\(element.label)”"
            if let value = element.value, !value.isEmpty { text += " = \(value.prefix(60))" }
            if let place = element.place { text += " · \(place)" }
            return text
        }
        var heads: [String: [String: String]] = [:]
        let pressable = elements.filter { !Set($0.operations).isDisjoint(with: ["press", "select", "click"]) }
        let typeable = elements.filter { $0.operations.contains("type") }
        heads["press_target"] = Dictionary(pressable.map { ($0.ref, describe($0)) }, uniquingKeysWith: { first, _ in first })
        heads["type_target"] = Dictionary(typeable.map { ($0.ref, describe($0)) }, uniquingKeysWith: { first, _ in first })
        heads["app_target"] = indexed("a", observation.apps)
        heads["folder_target"] = indexed("f", observation.folders)
        heads["site_target"] = indexed("s", sites)
        heads["menu_target"] = indexed("m", observation.menus)
        if !typeable.isEmpty, !words.isEmpty {
            let options = indexed("w", words.prefix(JevClient.maxOptions).enumerated().map { "\($0.offset + 1): \($0.element)" })
            heads["type_from"] = options
            heads["type_to"] = options
        }

        var operations: [String: String] = [
            "WAIT": "The needed control is absent or results are still loading; wait one moment.",
            "DONE": "The current screen shows the whole goal is already satisfied.",
            "BLOCKED": "No offered operation can make progress toward the goal.",
            "PRESS_RETURN": "Press Return in the focused input, e.g. to submit a typed search.",
            "SCROLL_DOWN": "Scroll down to reveal more of the window.",
            "SCROLL_UP": "Scroll up.",
        ]
        if !pressable.isEmpty { operations["PRESS"] = "Press, select or click one of `elements`." }
        if !typeable.isEmpty { operations["TYPE_TEXT"] = "Type the text the user wants entered into an input in `elements`." }
        if !observation.apps.isEmpty { operations["OPEN_APP"] = "Open or bring to the front one of `available.apps`." }
        if !observation.folders.isEmpty { operations["OPEN_FOLDER"] = "Open one of `available.folders` in Finder." }
        if !sites.isEmpty { operations["OPEN_URL"] = "Open one of `available.sites` in the browser." }
        if !observation.menus.isEmpty { operations["MENU"] = "Choose one of `available.menus` in the app's menu bar." }
        return (state, operations, heads)
    }

    static func action(for operation: String, decision: JevClient.Decision, observation: Observation, words: [String]) -> Action? {
        func element(_ head: String) -> Observation.Element? {
            decision.choice(head).flatMap { choice in observation.elements.first { $0.ref == choice.id } }
        }
        func item(_ head: String, _ list: [String], prefix: String) -> String? {
            guard let id = decision.choice(head)?.id, id.hasPrefix(prefix), let index = Int(id.dropFirst(prefix.count)), list.indices.contains(index) else { return nil }
            return list[index]
        }
        let app = observation.application
        switch operation {
        case "PRESS":
            guard let target = element("press_target") else { return nil }
            let verb = target.operations.contains("press") ? "PRESS" : target.operations.contains("select") ? "SELECT" : "CLICK"
            return Action(operation: verb, fields: ["ref": target.ref], description: "Press “\(target.label)” in \(app)")
        case "TYPE_TEXT":
            guard let from = wordIndex(decision.choice("type_from")?.id), let to = wordIndex(decision.choice("type_to")?.id),
                from <= to, to < words.count
            else { return nil }
            let text = words[from...to].joined(separator: " ")
            var fields: [String: Any] = ["text": text]
            if let target = element("type_target") { fields["ref"] = target.ref }
            return Action(operation: "TYPE_TEXT", fields: fields, description: "Type “\(text)” in \(app)")
        case "OPEN_APP":
            guard let name = item("app_target", observation.apps, prefix: "a") else { return nil }
            return Action(operation: "OPEN_APP", fields: ["app": name], description: "Open \(name)")
        case "OPEN_FOLDER":
            guard let name = item("folder_target", observation.folders, prefix: "f") else { return nil }
            return Action(operation: "OPEN_FOLDER", fields: ["path": name], description: "Open the \(name) folder")
        case "OPEN_URL":
            let sites = observation.sites + sitesMentioned(in: words.joined(separator: " "))
            guard let site = item("site_target", sites, prefix: "s") else { return nil }
            let url = site.contains("://") ? site : "https://" + site
            return Action(operation: "OPEN_URL", fields: ["url": url], description: "Open \(site)")
        case "MENU":
            guard let menu = item("menu_target", observation.menus, prefix: "m") else { return nil }
            return Action(operation: "MENU", fields: ["menu": menu], description: "Choose \(menu) in \(app)")
        case "PRESS_RETURN":
            return Action(operation: "PRESS_KEY", fields: ["key": "return"], description: "Press Return in \(app)")
        case "SCROLL_DOWN", "SCROLL_UP":
            let direction = operation == "SCROLL_DOWN" ? "down" : "up"
            return Action(operation: "SCROLL", fields: ["direction": direction], description: "Scroll \(direction) in \(app)")
        default:
            return nil
        }
    }

    static func indexed(_ prefix: String, _ items: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.prefix(JevClient.maxOptions).enumerated().map { ("\(prefix)\($0.offset)", $0.element) })
    }

    static func wordIndex(_ id: String?) -> Int? {
        guard let id, id.hasPrefix("w") else { return nil }
        return Int(id.dropFirst())
    }

    /// Domains and URLs written in the goal ("open github.com"), so OPEN_URL has something to choose.
    static func sitesMentioned(in text: String) -> [String] {
        let pattern = #"(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func describe(_ observation: Observation) -> String {
        var lines = ["observation \(observation.id) · \(observation.application) — \(observation.window)"]
        for element in observation.elements.prefix(150) {
            var line = "\(element.ref) \(element.role) “\(element.label)”"
            if let value = element.value, !value.isEmpty { line += " = \(value.prefix(80))" }
            line += " [\(element.operations.joined(separator: ","))]"
            lines.append(line)
        }
        if !observation.menus.isEmpty { lines.append("menus: " + observation.menus.prefix(40).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}
