import BackgroundTasks
import Foundation

@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()
    static let identifier = "dev.local.agent.BackgroundSpike.work"
    @Published var busy = false
    var seconds = 120
    var reportsProgress = true
    private var work: Task<Void, Never>?
    private var cancelled = false

    func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            Task { @MainActor in
                guard let task = task as? BGContinuedProcessingTask else { return }
                self.accept(task)
            }
        }
        Journal.shared.emit("registered", ["success": registered,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "gpu": BGTaskScheduler.supportedResources.contains(.gpu)])
    }

    func submit(queued: Bool) async {
        guard !busy else { return }
        busy = true
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier,
            title: "JavaScript agent spike", subtitle: "\(seconds) steps")
        request.strategy = queued ? .queue : .fail
        Journal.shared.emit("continued_submit", ["strategy": queued ? "queue" : "fail", "seconds": seconds])
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            Journal.shared.emit("continued_submitted")
        } catch {
            busy = false
            Journal.shared.error("continued_submission_error", error)
        }
    }

    private func accept(_ task: BGContinuedProcessingTask) {
        Journal.shared.emit("continued_handler_started")
        task.expirationHandler = {
            Task { @MainActor in
                Journal.shared.emit("continued_expired")
                self.cancel()
            }
        }
        work = Task {
            do {
                try await run(mode: "continued", seconds: seconds, progress: task.progress, reportsProgress: reportsProgress)
                task.setTaskCompleted(success: true)
                Journal.shared.emit("continued_completed")
            } catch {
                task.setTaskCompleted(success: false)
                Journal.shared.error("continued_work_error", error)
            }
        }
    }

    func run(mode: String, seconds: Int, progress: Progress?, reportsProgress: Bool, resume: Bool = false) async throws {
        busy = true
        cancelled = false
        defer { busy = false }
        Journal.shared.emit("work_started", ["mode": mode, "seconds": seconds, "reportsProgress": reportsProgress, "resume": resume])
        let engine = try JavaScriptWork(reloadAt: 5, resume: resume)
        progress?.totalUnitCount = Int64(seconds)
        progress?.completedUnitCount = Int64(engine.steps)
        progress?.localizedDescription = "On-device JavaScript agent"
        while engine.steps < seconds {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            try engine.tick()
            if reportsProgress { progress?.completedUnitCount = Int64(engine.steps) }
        }
        Journal.shared.emit("work_completed", ["mode": mode, "steps": engine.steps, "generation": engine.generation])
    }

    func control(resume: Bool = false) {
        guard !busy else { return }
        work = Task {
            do { try await run(mode: "unprotected_control", seconds: seconds, progress: nil, reportsProgress: false, resume: resume) }
            catch { Journal.shared.error("control_work_error", error) }
        }
    }

    func cancel() {
        cancelled = true
        work?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        busy = false
        Journal.shared.emit("cancel_requested")
    }
}
