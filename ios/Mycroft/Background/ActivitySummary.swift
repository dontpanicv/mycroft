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
        case "hands_exec", "bash":
            return Step(headline: "Running `\(string("command") ?? "a command")`\(on)", machine: machine, kind: .command)
        case "hands_job_start":
            return Step(headline: "Started `\(string("command") ?? "a job")`\(on)", machine: machine, kind: .command)
        case "hands_job_wait", "hands_job_output", "hands_job_status":
            return Step(headline: "Watching a job\(on)", machine: machine, kind: .read)
        case "hands_read", "read":
            return Step(headline: "Reading \(file(string("path")))\(on)", machine: machine, kind: .read)
        case "hands_write", "write", "hands_edit", "edit":
            return Step(headline: "Editing \(file(string("path")))\(on)", machine: machine, kind: .file)
        case "hands_list", "ls":
            return Step(headline: "Looking through \(file(string("path")))\(on)", machine: machine, kind: .read)
        case "desktop_do":
            return Step(headline: "\(machine ?? "Mac"): \(string("goal") ?? "using apps")", machine: machine, kind: .desktop)
        case "ui_observe":
            return Step(headline: "Looking at \(string("app") ?? "the screen")\(on)", machine: machine, kind: .desktop)
        case "ui_act":
            let action = string("action") ?? "Using"
            let target = string("target").map { " “\($0)”" } ?? ""
            let app = string("app").map { " in \($0)" } ?? ""
            return Step(headline: "\(action.capitalized)\(target)\(app)\(on)", machine: machine, kind: .desktop)
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

    private static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}
