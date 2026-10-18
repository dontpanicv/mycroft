import PiDurableKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var jevKey = ""
    @State private var jevSaved = false
    @State private var openAIKey = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Model") {
                        SignInPrompt()
                    }
                    section("Live voice · GPT-Live") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Live voice uses OpenAI's GPT-Live, which needs a platform API key (the ChatGPT subscription doesn't cover it). The key stays in this iPhone's keychain.")
                                .font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                            HStack {
                                SecureField(app.hasOpenAIKey ? "Key saved — paste to replace" : "Paste OpenAI API key", text: $openAIKey)
                                    .font(.mono(13))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button(openAIKey.isEmpty && app.hasOpenAIKey ? "Remove" : "Save") {
                                    try? app.saveOpenAIKey(openAIKey)
                                    openAIKey = ""
                                }
                                .buttonStyle(.glass)
                                .disabled(openAIKey.isEmpty && !app.hasOpenAIKey)
                            }
                            Tag(text: app.hasOpenAIKey ? "Key saved" : "No key", color: app.hasOpenAIKey ? Theme.success : Theme.inkMuted)
                        }
                        .hairlineCard()
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
                        MachinesSection()
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
    @State private var working = false
    @State private var page: URL?

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
                Text("Your sign-in code").font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                Text(code).font(.mono(30, weight: .bold)).tracking(4).foregroundStyle(Theme.accentSoft).textSelection(.enabled)
                    .accessibilityIdentifier("deviceCode")
                Button {
                    UIPasteboard.general.string = code
                    page = url
                } label: {
                    MonoLabel("Copy code & open sign-in", color: .white, size: 12).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                Text("Paste the code on the page, approve, then close the page. Or enter it at \(url.host() ?? "auth.openai.com")\(url.path()) on any other device. Keep Mycroft open until it says you're signed in.")
                    .font(.grotesk(13)).foregroundStyle(Theme.inkFaint)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.accentSoft)
                    MonoLabel("Waiting for approval", size: 10)
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
        .sheet(item: $page) { url in
            SafariSheet(url: url).ignoresSafeArea()
        }
        .onChange(of: app.signIn) {
            if app.signIn == .signedIn { page = nil }
        }
    }

    private var signInButton: some View {
        Button {
            working = true
            Task {
                await app.signInWithChatGPT()
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
