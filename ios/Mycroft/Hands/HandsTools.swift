import Foundation
import PiDurableKit

/// The agent's hands: tools that act on paired machines through their `hands` listener.
///
/// Commands run as supervised jobs keyed by the durable tool task, so `hands_exec` is replay-safe: if iOS suspends or
/// kills Mycroft mid-command, the rerun reattaches to the same job instead of starting the command again.
nonisolated enum HandsTools {
    struct ExecArguments: Decodable, Sendable {
        var machine: String
        var command: String
        var cwd: String?
        var timeout_s: Int?
    }

    struct JobArguments: Decodable, Sendable {
        var machine: String
        var key: String
        var timeout_s: Int?
    }

    struct PathArguments: Decodable, Sendable {
        var machine: String
        var path: String
    }

    struct WriteArguments: Decodable, Sendable {
        var machine: String
        var path: String
        var content: String
    }

    struct EditArguments: Decodable, Sendable {
        var machine: String
        var path: String
        var old_text: String
        var new_text: String
    }

    struct MachineArguments: Decodable, Sendable {
        var machine: String
    }

    static let maxOutput = 16_000

    static func makeExtension() -> Extension {
        Extension("mycroft.hands") {
            PromptSection("machines") { input in
                let list = try await input.document(Machines.document)
                guard !list.items.isEmpty else {
                    return "No machines are paired yet. If the user needs a shell, files or desktop control, tell them to add a machine in Settings → Machines."
                }
                let lines = list.items.map { machine in
                    let reach = machine.hosts.joined(separator: ", ")
                    return "- \(machine.name): \(machine.displayOS) \(machine.arch); reachable as \(reach)"
                }
                return """
                    Machines paired with hands. Every hands_* tool takes `machine`; use the exact name below.
                    \(lines.joined(separator: "\n"))
                    - The user may say "the Mac", "the Linux box" or "the server": pick the machine that matches; ask only if two match.
                    - The user often talks instead of typing, and on-device speech recognition turns unusual names into sound-alikes ("vendor too" for bender-2). Match what you read to these names by sound.
                    - You can use several machines in one turn. Calls in the same step run at the same time, so start independent work on different machines together.
                    - For something that must keep running while you do other things (a server, a watcher, a build), use hands_job_start, and stop it with hands_job_cancel when you are done.
                    - When one machine has to reach another, use the other machine's address from this list, not localhost.
                    """
            }

            Tool("hands_machines", description: "List the paired machines and whether each one is reachable right now.", replay: .safe) {
                (call: ToolCallContext) -> String in
                let list = try await call.harness.document(Machines.document)
                guard !list.items.isEmpty else { return "No machines are paired." }
                var lines: [String] = []
                for machine in list.items {
                    let status: String
                    do {
                        let info = try await HandsPool.shared.connection(to: machine).info
                        status = "online, home \(info?.string("home") ?? "?")"
                    } catch {
                        status = "unreachable (\(error.localizedDescription))"
                    }
                    lines.append("\(machine.name) — \(machine.displayOS) \(machine.arch), hands \(machine.version): \(status)")
                }
                return lines.joined(separator: "\n")
            }

            Tool(
                "hands_exec",
                description: "Run a shell command on a paired machine and return its output and exit code. It runs as a supervised job: if it is still running after timeout_s (default 600), you get its job key and can keep waiting with hands_job_wait.",
                parameters: .object([
                    "machine": .string("Machine name"),
                    "command": .string("Shell command, run with bash -c"),
                    "cwd": .string("Working directory; ~ and relative paths start at the user's home").optional,
                    "timeout_s": .integer("How long to wait before returning (default 600)").optional,
                ]),
                replay: .safe
            ) { (args: ExecArguments, call) -> ToolResult in
                let machine = try await resolve(args.machine, call)
                let key = "mycroft-\(call.taskId.rawValue)"
                return try await HandsPool.shared.with(machine) { hands in
                    var fields: [String: Any] = ["key": key, "command": args.command]
                    if let cwd = args.cwd { fields["cwd"] = try await absolute(cwd, hands) }
                    _ = try await hands.request("job.start", fields)
                    do {
                        return try await follow(key, on: hands, machine: machine, timeout: args.timeout_s ?? 600, call: call)
                    } catch is CancellationError {
                        // The user stopped the run: stop the command on the machine too (its whole process group).
                        await Task.detached { _ = try? await hands.request("job.cancel", ["key": key]) }.value
                        throw CancellationError()
                    }
                }
            }

            Tool(
                "hands_job_start",
                description: "Start a long-running command on a paired machine and return at once with its job key. The job keeps running even when the phone is offline.",
                parameters: .object([
                    "machine": .string("Machine name"),
                    "command": .string("Shell command, run with bash -c"),
                    "cwd": .string("Working directory").optional,
                ]),
                replay: .safe
            ) { (args: ExecArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                let key = "mycroft-\(call.taskId.rawValue)"
                return try await HandsPool.shared.with(machine) { hands in
                    var fields: [String: Any] = ["key": key, "command": args.command]
                    if let cwd = args.cwd { fields["cwd"] = try await absolute(cwd, hands) }
                    let started = try await hands.request("job.start", fields)
                    return "Job \(key) is \(started.string("state") ?? "running") on \(machine.name)."
                }
            }

            Tool(
                "hands_job_wait",
                description: "Wait for a job on a machine to finish (up to timeout_s, default 600) and return its output and exit code.",
                parameters: .object([
                    "machine": .string("Machine name"), "key": .string("Job key"),
                    "timeout_s": .integer("Seconds to wait").optional,
                ]),
                replay: .safe
            ) { (args: JobArguments, call) -> ToolResult in
                let machine = try await resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    try await follow(args.key, on: hands, machine: machine, timeout: args.timeout_s ?? 600, call: call)
                }
            }

            Tool(
                "hands_job_cancel",
                description: "Stop a job on a machine (its whole process group).",
                parameters: .object(["machine": .string("Machine name"), "key": .string("Job key")])
            ) { (args: JobArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                let status = try await HandsPool.shared.with(machine) { try await $0.request("job.cancel", ["key": args.key]) }
                return "Job \(args.key) is \(status.string("state") ?? "cancelled")."
            }

            Tool(
                "hands_jobs", description: "List recent jobs on a machine.",
                parameters: .object(["machine": .string("Machine name")]), replay: .safe
            ) { (args: MachineArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                let reply = try await HandsPool.shared.with(machine) { try await $0.request("job.list") }
                let jobs = (reply["jobs"] as? [[String: Any]]) ?? []
                guard !jobs.isEmpty else { return "No jobs on \(machine.name)." }
                return jobs.prefix(30).map { job in
                    "\(job["key"] ?? "?")  \(job["state"] ?? "?")  exit \(job["exitCode"] ?? "-")  \(job["command"] ?? job["argv"] ?? "")"
                }.joined(separator: "\n")
            }

            Tool(
                "hands_read", description: "Read a text file on a machine (up to 512 KB).",
                parameters: .object(["machine": .string("Machine name"), "path": .string("File path; ~ is the user's home")]),
                replay: .safe
            ) { (args: PathArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    try await readText(try await absolute(args.path, hands), on: hands)
                }
            }

            Tool(
                "hands_write", description: "Create or overwrite a text file on a machine, creating missing folders.",
                parameters: .object([
                    "machine": .string("Machine name"), "path": .string("File path"), "content": .string("The full file content"),
                ]),
                replay: .safe
            ) { (args: WriteArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    let path = try await absolute(args.path, hands)
                    _ = try await hands.request("write", ["path": path, "append": false], payload: Data(args.content.utf8))
                    return "Wrote \(args.content.utf8.count) bytes to \(path) on \(machine.name)."
                }
            }

            Tool(
                "hands_edit",
                description: "Replace one exact occurrence of old_text with new_text in a file on a machine.",
                parameters: .object([
                    "machine": .string("Machine name"), "path": .string("File path"),
                    "old_text": .string("Text to find; must occur exactly once"), "new_text": .string("Replacement"),
                ])
            ) { (args: EditArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    let path = try await absolute(args.path, hands)
                    let text = try await readText(path, on: hands)
                    let count = text.components(separatedBy: args.old_text).count - 1
                    guard count == 1 else {
                        throw ToolError("old_text occurs \(count) times in \(path); it must occur exactly once")
                    }
                    let updated = text.replacingOccurrences(of: args.old_text, with: args.new_text)
                    _ = try await hands.request("write", ["path": path, "append": false], payload: Data(updated.utf8))
                    return "Edited \(path) on \(machine.name)."
                }
            }

            Tool(
                "hands_list", description: "List files below a folder on a machine (respects .gitignore, at most 400 entries).",
                parameters: .object(["machine": .string("Machine name"), "path": .string("Folder path")]),
                replay: .safe
            ) { (args: PathArguments, call) -> String in
                let machine = try await resolve(args.machine, call)
                return try await HandsPool.shared.with(machine) { hands in
                    let path = try await absolute(args.path, hands)
                    let reply = try await hands.request("listFiles", ["path": path, "maxEntries": 400])
                    return listing(reply, root: path)
                }
            }
        }
    }

    // MARK: Helpers

    static func resolve(_ name: String, _ call: ToolCallContext) async throws -> Machine {
        let list = try await call.harness.document(Machines.document)
        guard let machine = list.named(name) else {
            let names = list.items.map(\.name).joined(separator: ", ")
            throw ToolError(names.isEmpty ? "No machines are paired." : "No machine named \(name). Paired: \(names)")
        }
        return machine
    }

    /// The daemon wants absolute paths: `~` and relative paths start at the user's home.
    static func absolute(_ path: String, _ hands: HandsConnection) async throws -> String {
        if path.hasPrefix("/") { return path }
        let home = await hands.info?.string("home") ?? "/"
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        return home + "/" + path
    }

    /// Streams a job's output into the tool's live output until it ends or `timeout` passes.
    static func follow(_ key: String, on hands: HandsConnection, machine: Machine, timeout: Int, call: ToolCallContext) async throws -> ToolResult {
        let deadline = Date.now.addingTimeInterval(TimeInterval(max(1, timeout)))
        var offset = 0
        var tail = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try await hands.request("job.output", ["key": key, "offset": offset, "maxBytes": 256 * 1024])
            if !chunk.payload.isEmpty {
                call.output(String(decoding: chunk.payload, as: UTF8.self))
                tail.append(chunk.payload)
                if tail.count > maxOutput * 2 { tail = tail.suffix(maxOutput) }
            }
            offset = chunk.int("nextOffset") ?? offset + chunk.payload.count
            if chunk.bool("eof") { break }
            if Date.now >= deadline {
                return ToolResult(output: [.text("Still running on \(machine.name) as job \(key). Output so far:\n\(text(tail))\nUse hands_job_wait to keep waiting.")])
            }
            let remaining = Int(deadline.timeIntervalSinceNow * 1000)
            _ = try await hands.request("job.wait", ["key": key, "timeoutMs": max(250, min(3000, remaining))])
        }
        let status = try await hands.request("job.status", ["key": key])
        let state = status.string("state") ?? "exited"
        let code = status.int("exitCode")
        let summary = "\(state)\(code.map { ", exit code \($0)" } ?? "") on \(machine.name)"
        return ToolResult(output: [.text("\(text(tail))\n[\(summary)]")], isError: code.map { $0 != 0 } ?? (state != "exited"))
    }

    static func readText(_ path: String, on hands: HandsConnection) async throws -> String {
        let opened = try await hands.request("open", ["path": path, "mode": "read"])
        guard let handle = opened.int("handle") else { throw ToolError("could not open \(path)") }
        let read = await Result(catching: { try await hands.request("pread", ["handle": handle, "offset": 0, "length": 512 * 1024]) })
        _ = try? await hands.request("close", ["handle": handle])
        return String(decoding: try read.get().payload, as: UTF8.self)
    }

    /// A whole file's bytes, up to `limit`.
    static func readData(_ path: String, on hands: HandsConnection, limit: Int) async throws -> Data {
        let opened = try await hands.request("open", ["path": path, "mode": "read"])
        guard let handle = opened.int("handle") else { throw ToolError("could not open \(path)") }
        let read = await Result(catching: { () async throws -> Data in
            var data = Data()
            let chunk = 1024 * 1024
            while true {
                let piece = try await hands.request("pread", ["handle": handle, "offset": data.count, "length": chunk]).payload
                data.append(piece)
                if piece.count < chunk { return data }
                guard data.count <= limit else { throw ToolError("\(path) is over \(limit / 1024 / 1024) MB") }
            }
        })
        _ = try? await hands.request("close", ["handle": handle])
        return try read.get()
    }

    static func listing(_ reply: HandsConnection.Reply, root: String) -> String {
        // Records: kind byte (f/d/l), relative path, NUL.
        var lines: [String] = []
        for record in reply.payload.split(separator: 0) where record.count > 1 {
            let kind = record.first == UInt8(ascii: "d") ? "/" : ""
            lines.append(String(decoding: record.dropFirst(), as: UTF8.self) + kind)
        }
        let truncated = reply.bool("truncated") ? "\n(truncated)" : ""
        return lines.isEmpty ? "\(root) is empty." : lines.joined(separator: "\n") + truncated
    }

    static func text(_ data: Data) -> String {
        let string = String(decoding: data, as: UTF8.self)
        return string.count > maxOutput ? "…" + string.suffix(maxOutput) : string
    }
}

nonisolated struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Result where Failure == Error {
    /// `Result` from an async throwing body.
    nonisolated init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
