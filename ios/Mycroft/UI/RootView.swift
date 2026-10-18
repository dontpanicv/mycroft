import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [ThreadMeta] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch app.phase {
                case .starting:
                    StartingView()
                case .failed(let message):
                    FailedView(message: message)
                case .ready:
                    ThreadListView(path: $path)
                }
            }
            .navigationDestination(for: ThreadMeta.self) { thread in
                ThreadView(thread: thread)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .accessibilityIdentifier("settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

private struct StartingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accentSoft)
            MonoLabel("Waking the brain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(grid: true)
    }
}

private struct FailedView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel("Mycroft could not start", color: Theme.danger)
            Text(message).font(.mono(12)).foregroundStyle(Theme.inkMuted).textSelection(.enabled)
        }
        .hairlineCard(padding: 16)
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(grid: true)
    }
}
