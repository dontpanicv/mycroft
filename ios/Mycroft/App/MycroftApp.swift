import SwiftUI

@main
struct MycroftApp: App {
    @State private var app = AppModel.shared

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
    }
}
