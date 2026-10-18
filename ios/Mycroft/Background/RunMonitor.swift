import ActivityKit
import Foundation
import PiDurableKit
import os

/// Follows every busy thread and tells the user what Mycroft is doing, wherever they look:
/// a Live Activity (Lock Screen + Dynamic Island) per run, and the continued-processing banner.
///
/// It polls the durable state (`liveState`, the newest entries) instead of holding views open, so it works the same in
/// the foreground, in the background, and for runs Pi Durable resumed after a relaunch.
final class RunMonitor {
    static let shared = RunMonitor()

    private struct Track {
        var activity: Activity<RunActivityAttributes>?
        var state: RunActivityAttributes.ContentState
        var seenCalls: Set<String> = []
        var steps: [ActivitySummary.Step] = []
    }

    private weak var app: AppModel?
    private var tracks: [ConversationID: Track] = [:]
    private var loop: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.mycroft", category: "activity")

    /// The newest headline of any running thread, for the background-task banner.
    private(set) var headline: (thread: String, text: String)?
    var isTracking: Bool { !tracks.isEmpty }

    func attach(_ app: AppModel) {
        self.app = app
        kick()
    }

    /// Starts following runs. Cheap to call often; one loop runs at a time.
    func kick() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.follow()
            self?.loop = nil
        }
    }

    private func follow() async {
        var quiet = 0
        while !Task.isCancelled, let app {
            let snapshots = await app.busySnapshots()
            let busy = Set(snapshots.map(\.thread.id))
            for snapshot in snapshots { await update(snapshot, generation: app.generation.active) }
            for (id, track) in tracks where !busy.contains(id) {
                await finish(id, track, app: app)
            }
            quiet = snapshots.isEmpty ? quiet + 1 : 0
            if quiet >= 3, tracks.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    private func update(_ snapshot: AppModel.RunSnapshot, generation: Int) async {
        let isNew = tracks[snapshot.thread.id] == nil
        var track = tracks[snapshot.thread.id] ?? Track(state: .init(
            phase: .thinking, headline: "Thinking", machine: nil, step: 0, generation: generation, startedAt: .now))

        for call in snapshot.calls where !track.seenCalls.contains(call.id) {
            track.seenCalls.insert(call.id)
            track.steps.append(ActivitySummary.describe(tool: call.name, arguments: call.arguments))
        }
        let running = snapshot.live.tools.first { $0.status != .done }
        var next = track.state
        next.step = track.steps.count
        next.generation = generation
        if let running, let call = snapshot.calls.first(where: { $0.id == running.callId }) {
            let step = ActivitySummary.describe(tool: call.name, arguments: call.arguments)
            next.phase = .working
            next.headline = step.headline
            next.machine = step.machine
        } else if snapshot.live.generation?.message?.content.contains(where: { ($0.text ?? "").isEmpty == false }) == true {
            next.phase = .writing
            next.headline = "Writing the answer"
            next.machine = nil
        } else {
            next.phase = .thinking
            next.headline = "Thinking"
            next.machine = nil
        }
        // Every recorded step, newest first, minus the one on screen — fast steps finish between polls.
        next.recent = Array(track.steps.reversed().map(\.headline).filter { $0 != next.headline }.prefix(3))

        if isNew {
            track.activity = start(snapshot.thread, next)
        } else if next != track.state, let activity = track.activity {
            await Self.update(UncheckedSendable(activity), ActivityContent(state: next, staleDate: .now.addingTimeInterval(120)))
        }
        track.state = next
        tracks[snapshot.thread.id] = track
        headline = (snapshot.thread.title, next.headline)
        RunController.shared.report(thread: snapshot.thread.title, headline: next.headline)
    }

    private func start(_ thread: ThreadMeta, _ state: RunActivityAttributes.ContentState) -> Activity<RunActivityAttributes>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let activity = try Activity.request(
                attributes: RunActivityAttributes(threadTitle: thread.title, threadID: thread.id.rawValue),
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(120)))
            log.info("live activity started for thread \(thread.id.rawValue)")
            return activity
        } catch {
            // Live Activities can only start while the app is in the foreground; a run resumed in the background
            // is still reported through the background-task banner.
            log.notice("live activity not started: \(error)")
            return nil
        }
    }

    private func finish(_ id: ConversationID, _ track: Track, app: AppModel) async {
        tracks[id] = nil
        var final = track.state
        let stopReason = await app.lastStopReason(id)
        final.phase = stopReason == .error ? .failed : stopReason == .aborted ? .stopped : .done
        final.headline = ActivitySummary.closing(track.steps)
        final.machine = nil
        final.endedAt = .now
        final.recent = Array(track.steps.suffix(3).reversed().map(\.headline))
        if let activity = track.activity {
            await Self.end(UncheckedSendable(activity), ActivityContent(state: final, staleDate: nil))
        }
        if tracks.isEmpty { headline = nil }
    }

    // ActivityKit's Activity is safe to use from any task but isn't marked Sendable.
    private nonisolated static func update(
        _ activity: UncheckedSendable<Activity<RunActivityAttributes>>, _ content: ActivityContent<RunActivityAttributes.ContentState>
    ) async {
        await activity.value.update(content)
    }

    private nonisolated static func end(
        _ activity: UncheckedSendable<Activity<RunActivityAttributes>>, _ content: ActivityContent<RunActivityAttributes.ContentState>
    ) async {
        await activity.value.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
    }
}
