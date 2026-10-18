import Foundation
import PiDurableKit

/// Native tools that let the agent read and rewrite its own JavaScript (see agent/generation-0/SELF.md).
///
/// Activation installs the draft into the running harness with `harness.install`: pi-durable replaces the
/// extension named "mycroft" in place, the current phase finishes on the old code, and the next one runs the new code.
nonisolated enum SelfTools {
    struct PathArguments: Decodable, Sendable { var path: String? }
    struct WriteArguments: Decodable, Sendable { var path: String; var content: String }
    struct ActivateArguments: Decodable, Sendable { var note: String }
    struct RollbackArguments: Decodable, Sendable { var generation: Int? }

    static func makeExtension(store: GenerationStore, onActivate: @escaping @Sendable (Int) async -> Void) -> Extension {
        Extension("mycroft.self") {
            Tool(
                "self_read",
                description: "Read one of your own files (extension.js, SELF.md, or pi-durable docs under docs/pi-durable/). Without a path, list the readable files.",
                parameters: .object(["path": .string("Path relative to your generation, e.g. extension.js").optional]),
                replay: .safe
            ) { (args: PathArguments, _) -> String in
                guard let path = args.path, !path.isEmpty else { return try await store.list().joined(separator: "\n") }
                return try await store.read(path)
            }

            Tool(
                "self_write",
                description: "Write a file of your next generation (the draft). The draft starts as a copy of the active generation. Nothing changes until self_activate.",
                parameters: .object([
                    "path": .string("Path relative to your generation, e.g. extension.js"),
                    "content": .string("The complete new file content"),
                ]),
                replay: .safe
            ) { (args: WriteArguments, _) -> String in
                try await store.write(args.path, content: args.content)
                return "Wrote \(args.content.utf8.count) bytes to draft/\(args.path). Check it with self_diff, then self_activate."
            }

            Tool("self_diff", description: "Show how the draft differs from your active generation.", replay: .safe) {
                (_: ToolCallContext) -> String in
                try await store.diff()
            }

            Tool(
                "self_activate",
                description: "Load the draft into the running harness. If it fails to load, nothing changes and you get the error. If it loads, it becomes your next generation and your next step already runs it.",
                parameters: .object(["note": .string("What you changed and why, one sentence")])
            ) { (args: ActivateArguments, call) -> ToolResult in
                let (candidate, next) = try await store.draftExtension()
                do {
                    try await call.harness.install(candidate)
                } catch {
                    return ToolResult(output: [.text("Generation \(next) failed to load; still on the previous one.\n\(error)")], isError: true)
                }
                let generation = try await store.promoteDraft(note: args.note)
                await onActivate(generation)
                return ToolResult(output: [.text("Generation \(generation) is active: \(args.note)")])
            }

            Tool(
                "self_rollback",
                description: "Re-activate an earlier generation of yourself (the previous one by default).",
                parameters: .object(["generation": .integer("Generation to activate").optional])
            ) { (args: RollbackArguments, call) -> String in
                let state = await store.state
                let target = args.generation ?? state.history.map(\.generation).filter { $0 < state.active }.max() ?? 0
                try await call.harness.install(try await store.extensionFor(generation: target))
                try await store.activate(target)
                await onActivate(target)
                return "Generation \(target) is active again."
            }

            Tool("self_status", description: "Your generations: which is active, which last ran healthily, and why each was made.", replay: .safe) {
                (_: ToolCallContext) -> String in
                let state = await store.state
                let lines = state.history.sorted { $0.generation > $1.generation }.map { record in
                    "\(record.generation == state.active ? "*" : " ") \(record.generation)  \(record.createdAt.formatted(.iso8601))  \(record.note)"
                }
                return "active \(state.active), last good \(state.lastGood)\n" + lines.joined(separator: "\n")
            }
        }
    }
}
