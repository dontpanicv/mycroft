import PiDurableKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var jevKey = ""
    @State private var jevSaved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Model") {
                        SignInPrompt()
                    }
                    section("Desktop control · Jev") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Jev (typesafe.ai) picks the next action on your Mac from its accessibility tree. The key stays in this iPhone's keychain.")
                                .font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                            HStack {
                                SecureField(app.hasJevKey ? "Key saved — paste to replace" : "Paste Jev API key", text: $jevKey)
                                    .font(.mono(13))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button(jevKey.isEmpty && app.hasJevKey ? "Remove" : "Save") {
                                    try? app.saveJevKey(jevKey)
                                    jevKey = ""
                                    jevSaved = true
                                }
                                .buttonStyle(.glass)
                                .disabled(jevKey.isEmpty && !app.hasJevKey)
                            }
                            Tag(text: app.hasJevKey ? "Key saved" : "No key", color: app.hasJevKey ? Theme.success : Theme.inkMuted)
                        }
                        .hairlineCard()
                    }
                    section("Self") {
                        GenerationsList()
                    }
                    section("Machines") {
                        Text("Pair a Mac or Linux server running `hands` to give Mycroft a shell, long jobs and desktop control. Coming in milestone M5.")
                            .font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                            .hairlineCard()
                    }
                    section("About") {
                        NavigationLink("Open source notices") { Notices() }
                            .font(.mono(13))
                            .hairlineCard()
                    }
                }
                .padding(Theme.gutter)
            }
            .canvasBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title)
            content()
        }
    }
}

/// ChatGPT subscription sign-in with a device code.
struct SignInPrompt: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch app.signIn {
            case .signedIn:
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ChatGPT").font(.mono(15, weight: .semibold))
                        Text("Sol 6.1 is the default for new threads.").font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Button("Sign out") { Task { await app.signOut() } }.buttonStyle(.glass)
                }
            case .waitingForCode(let code, let url):
                Text("Enter this code at auth.openai.com").font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                Text(code).font(.mono(30, weight: .bold)).tracking(4).foregroundStyle(Theme.accentSoft).textSelection(.enabled)
                HStack {
                    Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }.buttonStyle(.glass)
                    Button("Open page", systemImage: "arrow.up.right") { openURL(url) }.buttonStyle(.glassProminent)
                }
            case .failed(let message):
                Text(message).font(.mono(12)).foregroundStyle(Theme.danger)
                signInButton
            case .signedOut, .unknown:
                Text("Sign in with your ChatGPT subscription to use Sol 6.1.").font(.grotesk(15)).foregroundStyle(Theme.ink)
                signInButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard()
    }

    private var signInButton: some View {
        Button {
            working = true
            Task {
                await app.signInWithChatGPT { url in Task { @MainActor in openURL(url) } }
                working = false
            }
        } label: {
            MonoLabel(working ? "Waiting…" : "Sign in with ChatGPT", color: .white, size: 12)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .disabled(working)
    }
}

private struct GenerationsList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.generation.history.sorted { $0.generation > $1.generation }) { record in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", record.generation)).font(.mono(11)).foregroundStyle(Theme.accentSoft)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.note).font(.grotesk(14)).foregroundStyle(Theme.ink)
                        Text(record.createdAt, format: .dateTime.day().month().hour().minute()).font(.mono(10.5))
                            .foregroundStyle(Theme.inkFaint)
                    }
                    Spacer()
                    if record.generation == app.generation.active {
                        Tag(text: "Active", color: Theme.accentSoft)
                    } else if record.generation == app.generation.lastGood {
                        Tag(text: "Last good")
                    }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .hairlineCard(padding: 12)
    }
}

private struct Notices: View {
    var body: some View {
        ScrollView {
            Text(PiDurable.thirdPartyNotices).font(.mono(10)).foregroundStyle(Theme.inkMuted).padding(Theme.gutter)
        }
        .canvasBackground()
        .navigationTitle("Notices")
    }
}
