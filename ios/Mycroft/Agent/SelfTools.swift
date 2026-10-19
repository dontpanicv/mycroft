import Foundation
import PiDurableKit

/// Native tools that let the agent read and rewrite itself — its behaviour (extension.js) and its screen (ui/) —
/// see agent/generation-0/SELF.md.
///
/// Activation installs the draft into the running harness with `harness.install` (pi-durable replaces the extension
/// named "mycroft" in place: the current phase finishes on the old code, the next one runs the new code) and swaps
/// the new screen into the running web view. A screen that fails to render never goes live.
nonisolated enum SelfTools {
    struct PathArguments: Decodable, Sendable { var path: String? }
    struct WriteArguments: Decodable, Sendable { var path: String; var content: String }
    struct ActivateArguments: Decodable, Sendable { var note: String }
    struct RollbackArguments: Decodable, Sendable { var generation: Int? }
    struct PreviewArguments: Decodable, Sendable { var route: String? }

    /// What the tools need from the app's screen and brain.
    struct Host: Sendable {
        /// Renders the draft's screen off-screen, optionally with a picture.
        var preview: @Sendable (_ route: String?, _ snapshot: Bool) async -> UIPreview.Result
        /// Puts a generation's screen up.
        var show: @Sendable (_ generation: Int) async -> WebUI.ShowResult
        /// Re-activates an earlier generation (agent and screen); returns the one now active.
        var rollBack: @Sendable (_ generation: Int?) async throws -> Int
        /// A generation became active.
        var activated: @Sendable (_ generation: Int) async -> Void
        /// Recent errors of the screen on display.
        var screenErrors: @Sendable () async -> [String]
    }

    static func makeExtension(store: GenerationStore, host: Host) -> Extension {
        Extension("mycroft.self") {
            // Native, so it holds for every generation.
            PromptSection("self", tag: false, text: """
                You are Mycroft, and Mycroft is this app — including everything on its screen. When the user talks \
                about Mycroft — how it looks, its layout, screens, buttons, colours, fonts, animations, its tone, what \
                it does or knows, its tools — they mean you. Change yourself; don't explain how they could.
                - The screen is your own web code in ui/ (Preact + htm, no build step; ui/README.md explains it). \
                Change any of it, or add whole new screens.
                - Your behaviour, prompt sections and JavaScript tools are extension.js.
                How: self_read the files you need, self_write each complete new file, self_preview to look at the \
                draft screen (fix what's wrong), then self_activate with a short note. It is live at once — the screen \
                reloads in place and the conversation continues. Say what changed and that "roll back" undoes it.
                Fixed native parts (need an app update): background runs, the Live Activity layout, the keychain, the \
                microphone and speech engines, the hands connection and the install server.
                """)

            Tool(
                "self_read",
                description: "Read one of your own files (extension.js, SELF.md, ui/*, or pi-durable docs under docs/pi-durable/). Without a path, list the readable files. Reads the draft if there is one.",
                parameters: .object(["path": .string("Path relative to your generation, e.g. ui/screens/thread.js").optional]),
                replay: .safe
            ) { (args: PathArguments, _) -> String in
                guard let path = args.path, !path.isEmpty else { return try await store.list().joined(separator: "\n") }
                return try await store.read(path)
            }

            Tool(
                "self_write",
                description: "Write a file of your next generation (the draft): extension.js, SELF.md, or anything under ui/ (new files too). The draft starts as a copy of the active generation. Nothing changes until self_activate.",
                parameters: .object([
                    "path": .string("Path relative to your generation, e.g. ui/style.css"),
                    "content": .string("The complete new file content"),
                ]),
                replay: .safe
            ) { (args: WriteArguments, _) -> String in
                try await store.write(args.path, content: args.content)
                let next = args.path.hasPrefix("ui/") ? "self_preview to see it, then self_activate" : "self_diff, then self_activate"
                return "Wrote \(args.content.utf8.count) bytes to draft/\(args.path). Next: \(next)."
            }

            Tool("self_diff", description: "Show how the draft differs from your active generation.", replay: .safe) {
                (_: ToolCallContext) -> String in
                try await store.diff()
            }

            Tool(
                "self_preview",
                description: "Look at your screen: renders the draft (or the active generation without a draft) off-screen at this iPhone's size, and returns a picture plus any errors it logged. route picks the screen: #/ (threads), #/t/<threadId>, #/settings, #/voice, or one you added.",
                parameters: .object(["route": .string("Hash route, default #/").optional]),
                replay: .safe
            ) { (args: PreviewArguments, _) -> ToolResult in
                let result = await host.preview(args.route, true)
                var output: [ContentBlock] = [.text(result.summary)]
                if let image = result.image { output.append(.image(ImageContent(data: image, mimeType: "image/jpeg"))) }
                return ToolResult(output: output, isError: result.outcome == .failed)
            }

            Tool(
                "self_activate",
                description: "Make the draft your next generation, live: checks that the draft's screen renders, loads its extension.js into the running harness, and swaps the new screen in. If anything fails, nothing changes and you get the error.",
                parameters: .object(["note": .string("What you changed and why, one sentence")])
            ) { (args: ActivateArguments, call) -> ToolResult in
                let (candidate, next) = try await store.draftExtension()
                let screenChanges = await store.draftUIChanges()
                var remarks: [String] = []
                if !screenChanges.isEmpty {
                    let check = await host.preview(nil, false)
                    if let problem = check.problem {
                        return ToolResult(output: [.text("Generation \(next) not activated: its screen doesn't render cleanly.\n\(problem)\nFix the draft and activate again.")], isError: true)
                    }
                    if check.outcome == .unavailable {
                        remarks.append("The screen couldn't be checked first because Mycroft is in the background; it loads (or rolls back by itself) when the user opens Mycroft.")
                    }
                }
                do {
                    try await call.harness.install(candidate)
                } catch {
                    return ToolResult(output: [.text("Generation \(next) failed to load; still on the previous one.\n\(error)")], isError: true)
                }
                let previous = await store.state.active
                let generation = try await store.promoteDraft(note: args.note)
                await host.activated(generation)
                switch await host.show(generation) {
                case .applied(let changed) where !changed.isEmpty:
                    remarks.append("The screen reloaded in place (\(changed.joined(separator: ", "))).")
                case .applied:
                    break
                case .notVisible:
                    if !screenChanges.isEmpty { remarks.append("The new screen shows when the user opens Mycroft.") }
                case .failed(let problem):
                    let back = (try? await host.rollBack(previous)) ?? previous
                    return ToolResult(output: [.text("Generation \(generation)'s screen failed on the phone, so Mycroft went back to generation \(back).\n\(problem)\nFix the draft (self_write starts a new one from generation \(back)) and try again.")], isError: true)
                }
                return ToolResult(output: [.text((["Generation \(generation) is active: \(args.note)"] + remarks).joined(separator: "\n"))])
            }

            Tool(
                "self_rollback",
                description: "Re-activate an earlier generation of yourself, agent and screen (the previous one by default).",
                parameters: .object(["generation": .integer("Generation to activate").optional])
            ) { (args: RollbackArguments, _) -> String in
                let target = try await host.rollBack(args.generation)
                return "Generation \(target) is active again."
            }

            Tool("self_status", description: "Your generations (which is active, which last ran healthily, why each was made) and recent errors of the screen.", replay: .safe) {
                (_: ToolCallContext) -> String in
                let state = await store.state
                let lines = state.history.sorted { $0.generation > $1.generation }.map { record in
                    "\(record.generation == state.active ? "*" : " ") \(record.generation)  \(record.createdAt.formatted(.iso8601))  \(record.note)"
                }
                let errors = await host.screenErrors()
                let screen = errors.isEmpty ? "Screen: no errors." : "Recent screen errors:\n" + errors.joined(separator: "\n")
                return "active \(state.active), last good \(state.lastGood)\n" + lines.joined(separator: "\n") + "\n" + screen
            }
        }
    }
}
