import SwiftUI

@main
struct MycroftApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RunController.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Journal.note("app_active")
                RunController.shared.appBecameActive()
                Task { await RunMonitor.shared.appBecameActive() }
            case .inactive, .background:
                // Progress is shown outside the app only while the user is away from it.
                guard !RunMonitor.shared.presenting else { return }
                Journal.note("app_leaving", ["phase": phase == .inactive ? "inactive" : "background"])
                RunMonitor.shared.appLeavingForeground()
                Task { await RunController.shared.appLeavingForeground() }
            @unknown default:
                break
            }
        }
    }
}
