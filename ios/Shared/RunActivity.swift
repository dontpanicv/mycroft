import ActivityKit
import Foundation

/// A Mycroft run on the Lock Screen and in the Dynamic Island. Shared by the app (which starts and updates it) and
/// the widget extension (which draws it).
nonisolated struct RunActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case thinking, working, writing, done, failed, stopped
        }

        var phase: Phase
        /// What Mycroft is doing right now, or at the end, what it did: "Running `cargo build` on hetzner".
        var headline: String
        /// The machine the current step runs on; nil when it's the phone itself.
        var machine: String?
        /// Tool calls so far in this run.
        var step: Int
        /// The agent's code generation running this step.
        var generation: Int
        var startedAt: Date
        var endedAt: Date?
        /// The previous few headlines, newest first, for the expanded island.
        var recent: [String] = []
        /// Mycroft's current accent tint ("#RRGGBB"), so the island follows appearance.json.
        var accent: String?

        var isFinished: Bool { phase == .done || phase == .failed || phase == .stopped }
    }

    var threadTitle: String
    var threadID: Int
}
