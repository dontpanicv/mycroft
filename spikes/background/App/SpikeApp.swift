import SwiftUI
import AppIntents
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Runner.shared.register()
        Journal.shared.emit("app_launched")
        return true
    }
}

@main
struct SpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) var phase
    var body: some Scene {
        WindowGroup {
            ProbeView()
                .onChange(of: phase) { _, value in
                    Journal.shared.emit("scene_\(value)")
                }
        }
    }
}

struct ProbeView: View {
    @ObservedObject private var journal = Journal.shared
    @ObservedObject private var runner = Runner.shared
    @State private var seconds = 120
    @State private var progress = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Experiment") {
                    Picker("Duration", selection: $seconds) {
                        Text("12 seconds").tag(12)
                        Text("2 minutes").tag(120)
                        Text("10 minutes").tag(600)
                        Text("1 hour").tag(3600)
                    }
                    Toggle("Report progress", isOn: $progress)
                    Text("JavaScript edits itself and restores its state at step 5.")
                }
                Section("Real platform APIs") {
                    Button("Start continued · fail if busy") { startContinued(queued: false) }
                        .accessibilityIdentifier("continuedFail")
                    Button("Start continued · queue") { startContinued(queued: true) }
                        .accessibilityIdentifier("continuedQueue")
                    Button(intent: RunProbeIntent(seconds: seconds, reportsProgress: progress)) {
                        Text("Start LongRunningIntent")
                    }.accessibilityIdentifier("longIntent")
                }
                Section("Controls") {
                    Button("Start without background permission") { runner.seconds = seconds; runner.control() }
                        .accessibilityIdentifier("control")
                    Button("Resume persisted JavaScript") { runner.seconds = seconds; runner.control(resume: true) }
                        .accessibilityIdentifier("resume")
                    Button("Stop", role: .destructive) { runner.cancel() }.accessibilityIdentifier("stop")
                }
                Section("Observed status") {
                    Text(journal.status).accessibilityIdentifier("status")
                    Text(journal.recent.joined(separator: "\n")).font(.caption.monospaced())
                }
            }.navigationTitle("Background Spike")
        }
        .onAppear {
            if let value = ProcessInfo.processInfo.environment["SPIKE_SECONDS"], let parsed = Int(value) {
                seconds = parsed
            }
            if ProcessInfo.processInfo.environment["SPIKE_REPORTS_PROGRESS"] == "false" {
                progress = false
            }
        }
        .onOpenURL { url in
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            seconds = Int(parts?.queryItems?.first(where: { $0.name == "seconds" })?.value ?? "120") ?? 120
            runner.seconds = seconds
            runner.reportsProgress = true
            if url.host == "continued" { startContinued(queued: false) }
            if url.host == "control" { runner.control() }
            if url.host == "resume" { runner.control(resume: true) }
        }
    }

    private func startContinued(queued: Bool) {
        runner.seconds = seconds
        runner.reportsProgress = progress
        Task { await runner.submit(queued: queued) }
    }
}
