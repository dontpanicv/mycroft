import BackgroundTasks
import Foundation
import UIKit
import os

/// Keeps the agent working after the user leaves the app.
///
/// When the user leaves the app while a run is going, Mycroft asks iOS for a continued-processing task (which shows
/// the system's progress banner). It is not requested while the app is open — the user is watching the run there —
/// and it is completed as soon as the user comes back. While any thread is busy
/// the task reports progress on every durable commit (iOS cancels tasks that stop reporting — about 58 s in the
/// spike) and completes once everything is idle. If iOS ends the task anyway, nothing is lost: Pi Durable resumes
/// the run on the next launch. Measured on iOS 27.2: runs of 10+ minutes in the background.
final class RunController {
    static let shared = RunController()

    static var identifier: String { (Bundle.main.bundleIdentifier ?? "dev.mycroft.app") + ".run" }

    private weak var app: AppModel?
    private var task: BGContinuedProcessingTask?
    private var requested = false
    private var progressWatcher: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.mycroft", category: "background")

    /// Must run before the app finishes launching.
    func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.accept(task)
            }
        }
        log.info("registered \(Self.identifier): \(registered)")
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    /// The user is leaving the app (scene going inactive). If something is running, ask iOS to keep it going.
    /// Continued processing can only be requested while the app is still in the foreground, so this happens now.
    func appLeavingForeground() async {
        guard task == nil, !requested, RunMonitor.shared.isTracking else { return }
        requested = true
        // Bridge the moments until iOS starts the continued-processing task.
        bridge = UIApplication.shared.beginBackgroundTask(withName: "Mycroft run") { [weak self] in self?.endBridge() }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: "Mycroft is working",
                                                       subtitle: RunMonitor.shared.headline?.text ?? "Working")
        request.strategy = .fail
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            Journal.note("bg_submitted")
        } catch {
            // The Simulator has no continued processing (BGTaskScheduler error 1).
            requested = false
            endBridge()
            log.notice("continued processing unavailable: \(error)")
            Journal.note("bg_failed", ["error": "\(error)"])
        }
    }

    /// The user is back: they can watch the run in the app, so the system banner goes away. Work continues.
    func appBecameActive() {
        endBridge()
        if task != nil { finish(success: true, reason: "foreground") }
        requested = false
    }

    private var bridge: UIBackgroundTaskIdentifier = .invalid

    private func endBridge() {
        guard bridge != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bridge)
        bridge = .invalid
    }

    private func accept(_ task: BGContinuedProcessingTask) {
        self.task = task
        endBridge()
        Journal.note("bg_accepted")
        task.progress.totalUnitCount = 1000
        // iOS calls this from its own queue; build it outside the main actor (see AudioTap).
        task.expirationHandler = AudioTap.completion { [weak self] in
            Task { @MainActor in self?.finish(success: false, reason: "expired") }
        }
        progressWatcher = Task { [weak self] in await self?.drive(task) }
    }

    /// Mirrors the run monitor's summary into the system's background-task banner.
    func report(thread: String, headline: String) {
        guard let task, task.subtitle != headline else { return }
        task.updateTitle("Mycroft · \(thread)", subtitle: headline)
    }

    /// Reports progress on every commit and finishes when all threads have been idle for a few seconds.
    private func drive(_ task: BGContinuedProcessingTask) async {
        guard let harness = app?.harness else { return finish(success: false, reason: "no harness") }
        let commits = Task {
            for try await _ in harness.commits() {
                let progress = task.progress
                progress.completedUnitCount = min(progress.completedUnitCount + 1, progress.totalUnitCount - 1)
            }
        }
        defer { commits.cancel() }
        var idleChecks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            RunMonitor.shared.kick()
            let busy = RunMonitor.shared.isTracking
            idleChecks = busy ? 0 : idleChecks + 1
            if busy {
                // Keep the indicator moving through long model waits too.
                let progress = task.progress
                progress.completedUnitCount = min(progress.completedUnitCount + 1, progress.totalUnitCount - 1)
            }
            if idleChecks >= 3 { return finish(success: true, reason: "idle") }
        }
    }

    private func finish(success: Bool, reason: String) {
        log.info("continued processing finished (\(reason))")
        Journal.note("bg_finished", ["reason": reason])
        progressWatcher?.cancel()
        progressWatcher = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
        requested = false
    }
}
