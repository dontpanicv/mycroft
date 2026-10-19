import SwiftUI

/// Mycroft's screen is its own web code (``WebUI``). The only native screen is the way out when that code is broken:
/// it appears when the screen fails to load, or when the user shakes the phone.
struct RootView: View {
    @State private var web = WebUI.shared
    @State private var shaken = false

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            // Under the keyboard the web view shrinks (it ignores only the container safe area), so the page's
            // composer stays above it.
            WebScreen().ignoresSafeArea(.container)
            if case .failed(let message) = web.status {
                RecoveryView(message: message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in shaken = true }
        .sheet(isPresented: $shaken) {
            RecoveryView(message: nil).presentationDetents([.medium, .large])
        }
    }
}

/// Reload the screen or go back to an earlier generation — native, so it works however broken the screen is.
struct RecoveryView: View {
    let message: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonoLabel(message == nil ? "Mycroft's screen" : "The screen didn't load", color: message == nil ? Theme.inkMuted : Theme.danger)
                Text("The screen is generation \(app.generation.active) of Mycroft's own code. If a change broke it, go back to an earlier generation; the conversations are not affected.")
                    .font(.grotesk(15)).foregroundStyle(Theme.ink)
                if let message {
                    Text(message).font(.mono(11)).foregroundStyle(Theme.inkMuted).textSelection(.enabled)
                        .hairlineCard(padding: 10)
                }
                Button {
                    WebUI.shared.reload()
                    dismiss()
                } label: {
                    MonoLabel("Reload the screen", color: .white, size: 12).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("recovery.reload")
                ForEach(earlier, id: \.generation) { record in
                    Button {
                        rollBack(to: record.generation)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            MonoLabel("Go back to generation \(record.generation)", color: Theme.ink, size: 11)
                            Text(record.note).font(.grotesk(13)).foregroundStyle(Theme.inkMuted).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .disabled(working)
                }
            }
            .padding(Theme.gutter)
            .padding(.top, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
    }

    /// The previous generations, newest first: the last good one, the one before the active, and generation 0.
    private var earlier: [GenerationStore.Record] {
        let state = app.generation
        let wanted = Set([state.lastGood, state.history.map(\.generation).filter { $0 < state.active }.max() ?? 0, 0])
            .subtracting([state.active])
        return state.history.filter { wanted.contains($0.generation) }.sorted { $0.generation > $1.generation }
    }

    private func rollBack(to generation: Int) {
        working = true
        Task {
            if let target = try? await app.rollBack(to: generation) {
                WebUI.shared.load(generation: target, recover: false)
            }
            working = false
            dismiss()
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("dev.mycroft.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
