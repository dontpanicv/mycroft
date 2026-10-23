import Foundation
import PiDurableKit

/// Turns tool calls into short sentences for the Dynamic Island and the background-task banner, so the user can see
/// at a glance what Mycroft is doing and on which machine: "Running `cargo build` on hetzner".
nonisolated enum ActivitySummary {
    enum Kind: Hashable { case command, file, read, desktop, selfEdit, other }

    struct Step: Hashable {
        var headline: String
        var machine: String?
        var kind: Kind
    }

    static func describe(tool: String, arguments: JSONObject) -> Step {
        func string(_ key: String) -> String? { arguments[key]?.stringValue.map(clip) }
        let machine = string("machine")
        let on = machine.map { " on \($0)" } ?? ""
        switch tool {
        case "self_read": return Step(headline: "Reading its own code", machine: nil, kind: .selfEdit)
        case "self_write": return Step(headline: "Rewriting itself", machine: nil, kind: .selfEdit)
        case "self_diff": return Step(headline: "Reviewing its own changes", machine: nil, kind: .selfEdit)
        case "self_activate": return Step(headline: activationHeadline, machine: nil, kind: .selfEdit)
        case "self_rollback": return Step(headline: "Rolling itself back", machine: nil, kind: .selfEdit)
        case "self_status": return Step(headline: "Checking its generations", machine: nil, kind: .read)
        case "hands_exec":
            return Step(headline: "Running `\(string("command") ?? "a command")`\(on)", machine: machine, kind: .command)
        case "hands_job_start":
            return Step(headline: "Started `\(string("command") ?? "a job")`\(on)", machine: machine, kind: .command)
        case "hands_job_wait":
            return Step(headline: "Watching a job\(on)", machine: machine, kind: .read)
        case "hands_job_cancel":
            return Step(headline: "Stopping a job\(on)", machine: machine, kind: .command)
        case "hands_jobs":
            return Step(headline: "Checking the jobs\(on)", machine: machine, kind: .read)
        case "hands_machines":
            return Step(headline: "Checking the machines", machine: nil, kind: .read)
        case "hands_read":
            return Step(headline: "Reading \(file(string("path")))\(on)", machine: machine, kind: .read)
        case "hands_write", "hands_edit":
            return Step(headline: "Editing \(file(string("path")))\(on)", machine: machine, kind: .file)
        case "hands_list":
            return Step(headline: "Looking through \(file(string("path")))\(on)", machine: machine, kind: .read)
        // Cua Driver's tools on a Mac (Desktop/CuaTools.swift).
        case "get_window_state", "get_accessibility_tree":
            let what = string("query").map { "for “\($0)”" } ?? "at \(string("app") ?? "a window")"
            return Step(headline: "Looking \(what)\(on)", machine: machine, kind: .desktop)
        case "get_desktop_state":
            return Step(headline: "Looking at the screen\(on)", machine: machine, kind: .read)
        case "list_apps", "list_windows":
            return Step(headline: "Checking the open apps\(on)", machine: machine, kind: .read)
        case "launch_app":
            return Step(headline: "Opening \(string("name") ?? string("bundle_id") ?? "an app")\(on)", machine: machine, kind: .desktop)
        case "bring_to_front":
            return Step(headline: "Bringing a window forward\(on)", machine: machine, kind: .desktop)
        case "kill_app":
            return Step(headline: "Force-quitting an app\(on)", machine: machine, kind: .desktop)
        case "click", "double_click", "right_click":
            return Step(headline: "Clicking\(on)", machine: machine, kind: .desktop)
        case "type_text", "type_text_chars":
            return Step(headline: "Typing \(string("text").map { "“\($0)”" } ?? "text")\(on)", machine: machine, kind: .desktop)
        case "press_key", "hotkey":
            let keys = (arguments["keys"]?.arrayValue?.compactMap(\.stringValue) ?? [string("key")].compactMap { $0 }).joined(separator: "+")
            return Step(headline: "Pressing \(keys.isEmpty ? "keys" : keys)\(on)", machine: machine, kind: .desktop)
        case "scroll":
            return Step(headline: "Scrolling\(string("direction").map { " \($0)" } ?? "")\(on)", machine: machine, kind: .desktop)
        case "set_value":
            return Step(headline: "Setting \(string("value").map { "“\($0)”" } ?? "a value")\(on)", machine: machine, kind: .desktop)
        case "invoke_menu":
            let path = arguments["path"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " > ")
            return Step(headline: "Choosing \(path.map(clip) ?? "a menu item")\(on)", machine: machine, kind: .desktop)
        case "run_steps":
            let count = arguments["steps"]?.arrayValue?.count ?? 0
            return Step(headline: "Running \(count > 0 ? plural(count, "step") : "steps") in an app\(on)", machine: machine, kind: .desktop)
        case "verify_state":
            return Step(headline: "Checking the result\(on)", machine: machine, kind: .read)
        case "now": return Step(headline: "Checking the time", machine: nil, kind: .read)
        default: return Step(headline: "Using \(tool)\(on)", machine: machine, kind: .other)
        }
    }

    /// One line for the end of a run: what Mycroft did, grouped by machine.
    static func closing(_ steps: [Step]) -> String {
        guard !steps.isEmpty else { return "Answered" }
        var parts: [String] = []
        let byMachine = Dictionary(grouping: steps.filter { $0.machine != nil }, by: { $0.machine! })
        for (machine, items) in byMachine.sorted(by: { $0.key < $1.key }) {
            let commands = items.filter { $0.kind == .command }.count
            let files = items.filter { $0.kind == .file }.count
            let clicks = items.filter { $0.kind == .desktop }.count
            var bits: [String] = []
            if commands > 0 { bits.append(plural(commands, "command")) }
            if files > 0 { bits.append(plural(files, "file edit")) }
            if clicks > 0 { bits.append(plural(clicks, "desktop step")) }
            if bits.isEmpty { bits.append(plural(items.count, "step")) }
            parts.append(bits.joined(separator: ", ") + " on \(machine)")
        }
        let rewrote = steps.contains { $0.headline == activationHeadline }
        let local = steps.filter { $0.machine == nil && $0.headline != activationHeadline }.count
        if local > 0 { parts.append(plural(local, "step") + " on the phone") }
        if rewrote { parts.append("rewrote itself") }
        return parts.joined(separator: " · ")
    }

    static let activationHeadline = "Loading its new generation"

    private static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    private static func file(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "files" }
        return (path as NSString).lastPathComponent
    }

    private static func clip(_ text: String) -> String { CuaTools.clip(text) }
}
