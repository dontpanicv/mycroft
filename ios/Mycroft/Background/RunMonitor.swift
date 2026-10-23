import ActivityKit
import Foundation
import PiDurableKit
import os

/// Follows every busy thread and tells the user what Mycroft is doing — but only while they are *not* looking at the
/// app: a Live Activity (Lock Screen + Dynamic Island) per run and the continued-processing banner appear when the user
/// leaves the app during a run, and disappear as soon as they come back.
///
/// It polls the durable state (`liveState`, the newest entries) instead of holding views open, so it works the same in
/// the foreground, in the background, and for runs Pi Durable resumed after a relaunch.
final class RunMonitor {
    static let shared = RunMonitor()

    private struct Track {
        var thread: ThreadMeta
        var activity: Activity<RunActivityAttributes>?
        var state: RunActivityAttributes.ContentState
        var seenCalls: Set<String> = []
        var steps: [ActivitySummary.Step] = []
        /// Set by ``runSubmitted(_:)``: the run may not report itself busy for a moment yet.
        var submittedAt: Date?
    }

    private weak var app: AppModel?
    private var tracks: [ConversationID: Track] = [:]
    private var loop: Task<Void, Never>?
    private var lastPoll = ""
    private let log = Logger(subsystem: "dev.mycroft", category: "activity")

    /// The newest headline of any running thread, for the background-task banner.
    private(set) var headline: (thread: String, text: String)?
    var isTracking: Bool { !tracks.isEmpty }
    /// True while the app is not in front: only then are Live Activities shown.
    private(set) var presenting = false

    func attach(_ app: AppModel) {
        self.app = app
        kick()
    }

    /// A message was just sent: follow its run from now on, so leaving the app right away still shows it.
    func runSubmitted(_ thread: ThreadMeta) {
        if tracks[thread.id] == nil {
            tracks[thread.id] = Track(thread: thread, state: .init(
                phase: .thinking, headline: "Thinking", machine: nil, step: 0, generation: app?.generation.active ?? 0,
                startedAt: .now), submittedAt: .now)
        }
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
            app.runsChanged(busy)
            let seen = "\(snapshots.count)/\(tracks.count)"
            if seen != lastPoll {
                lastPoll = seen
                Journal.note("poll", ["busy": "\(snapshots.count)", "tracked": "\(tracks.count)", "threads": "\(app.threads.count)",
                                      "first": app.threads.first.map { "\($0.id.rawValue) \($0.title)" } ?? "-"])
            }
            for snapshot in snapshots { await update(snapshot, generation: app.generation.active) }
            for (id, track) in tracks where !busy.contains(id) {
                // A just-submitted run may not show as busy yet.
                if let submitted = track.submittedAt, Date.now.timeIntervalSince(submitted) < 6 { continue }
                await finish(id, track, app: app)
            }
            quiet = snapshots.isEmpty ? quiet + 1 : 0
            if quiet >= 3, tracks.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    private func update(_ snapshot: AppModel.RunSnapshot, generation: Int) async {
        let isNew = tracks[snapshot.thread.id]?.activity == nil
        var track = tracks[snapshot.thread.id] ?? Track(thread: snapshot.thread, state: .init(
            phase: .thinking, headline: "Thinking", machine: nil, step: 0, generation: generation, startedAt: .now))
        track.submittedAt = nil

        for call in snapshot.calls where !track.seenCalls.contains(call.id) {
            track.seenCalls.insert(call.id)
            track.steps.append(ActivitySummary.describe(tool: call.name, arguments: call.arguments))
        }
        let running = snapshot.live.tools.first { $0.status != .done }
        var next = track.state
        next.accent = Appearance.shared.values.accentSoft
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

        if isNew, presenting {
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
            Journal.note("activity_started", ["thread": thread.title])
            return activity
        } catch {
            // Live Activities can only start while the app is still in the foreground; a run resumed in the
            // background is still reported through the background-task banner.
            log.notice("live activity not started: \(error)")
            Journal.note("activity_failed", ["thread": thread.title, "error": "\(error)"])
            return nil
        }
    }

    private func finish(_ id: ConversationID, _ track: Track, app: AppModel) async {
        tracks[id] = nil
        var final = track.state
        let outcome: ThreadMeta.Outcome = switch await app.lastStopReason(id) {
        case .error: .failed
        case .aborted: .stopped
        default: .done
        }
        final.phase = switch outcome {
        case .failed: .failed
        case .stopped: .stopped
        case .done: .done
        }
        await app.runFinished(id, outcome)
        final.headline = ActivitySummary.closing(track.steps)
        final.machine = nil
        final.endedAt = .now
        final.recent = Array(track.steps.suffix(3).reversed().map(\.headline))
        if let activity = track.activity {
            // Away from the app: keep the summary on the Lock Screen until the user opens Mycroft (or 15 minutes).
            let dismissal: ActivityUIDismissalPolicy = presenting ? .after(.now.addingTimeInterval(15 * 60)) : .immediate
            await Self.end(UncheckedSendable(activity), ActivityContent(state: final, staleDate: nil), dismissal)
        }
        Journal.note("run_finished", ["thread": track.thread.title, "summary": final.headline, "away": "\(presenting)"])
        if tracks.isEmpty { headline = nil }
    }

    // MARK: Foreground and background

    /// The user is leaving the app (scene going inactive): show every running thread in the Dynamic Island. This has
    /// to happen now — ActivityKit only starts Live Activities while the app is still in the foreground.
    func appLeavingForeground() {
        presenting = true
        // Synchronously, from the runs already being followed: a moment later the app is in the background.
        for (id, track) in tracks where track.activity == nil {
            tracks[id]?.activity = start(track.thread, track.state)
        }
        kick()
    }

    /// The user is back in the app: they can see the runs, so take everything off the Lock Screen and Dynamic Island.
    func appBecameActive() async {
        presenting = false
        for (id, track) in tracks {
            if let activity = track.activity { await Self.end(UncheckedSendable(activity), ActivityContent(state: track.state, staleDate: nil), .immediate) }
            tracks[id]?.activity = nil
        }
        // Summaries of runs that finished while the user was away, and leftovers from earlier launches.
        for activity in Activity<RunActivityAttributes>.activities {
            await Self.end(UncheckedSendable(activity), nil, .immediate)
        }
    }

    // ActivityKit's Activity is safe to use from any task but isn't marked Sendable.
    private nonisolated static func update(
        _ activity: UncheckedSendable<Activity<RunActivityAttributes>>, _ content: ActivityContent<RunActivityAttributes.ContentState>
    ) async {
        await activity.value.update(content)
    }

    private nonisolated static func end(
        _ activity: UncheckedSendable<Activity<RunActivityAttributes>>, _ content: ActivityContent<RunActivityAttributes.ContentState>?,
        _ dismissal: ActivityUIDismissalPolicy
    ) async {
        await activity.value.end(content, dismissalPolicy: dismissal)
    }
}
