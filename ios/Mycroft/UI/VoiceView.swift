import SwiftUI

/// Live voice: a glass orb on the dotted grid, the conversation in mono, Mycroft's steps as numbered rows.
struct VoiceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var voice: any VoiceEngine

    /// GPT-Live when an OpenAI key is saved; otherwise on-device transcription and speech.
    init(live: Bool) {
        _voice = State(initialValue: live ? VoiceSession() : OnDeviceVoice())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(voice.statusText, color: statusColor, size: 11)
                Spacer()
                Button("Close", systemImage: "xmark") { end() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)

            Spacer(minLength: 20)
            Orb(level: voice.level, speaking: voice.speaking, live: voice.isLive)
                .frame(width: 180, height: 180)
                .onTapGesture { end() }
            Spacer(minLength: 20)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let message = voice.failure {
                            Text(message).font(.mono(12)).foregroundStyle(Theme.danger).hairlineCard(padding: 10)
                        }
                        ForEach(Array(voice.lines.enumerated()), id: \.element.id) { index, line in
                            LineView(line: line, number: stepNumber(index))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                .frame(maxHeight: 300)
                .onChange(of: voice.lines.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Text("Tap the orb to hang up. Work Mycroft started keeps running in the Voice thread.")
                .font(.grotesk(12)).foregroundStyle(Theme.inkFaint)
                .padding(Theme.gutter)
        }
        .canvasBackground(grid: true)
        .task { await voice.start(app: app) }
        .onDisappear { voice.stop() }
    }

    private func end() {
        voice.stop()
        dismiss()
    }

    private var statusColor: Color {
        if voice.failure != nil { return Theme.danger }
        return voice.isLive ? Theme.accentSoft : Theme.inkMuted
    }

    private func stepNumber(_ index: Int) -> Int {
        voice.lines[...index].filter { $0.speaker == .step }.count
    }
}

private struct LineView: View {
    let line: VoiceLine
    let number: Int

    var body: some View {
        switch line.speaker {
        case .user:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonoLabel("You", color: Theme.inkFaint, size: 9)
                Text(line.text).font(.grotesk(15)).foregroundStyle(Theme.inkMuted)
            }
        case .mycroft:
            Text(line.text).font(.grotesk(16)).foregroundStyle(Theme.ink)
        case .step:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", number)).font(.mono(11)).foregroundStyle(Theme.accentSoft)
                Text(line.text).font(.mono(12)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// A Liquid Glass orb that breathes with the microphone and glows while Mycroft talks.
private struct Orb: View {
    let level: Double
    let speaking: Bool
    let live: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(speaking ? 0.9 : 0.55), Theme.accent.opacity(0)],
                                     center: .center, startRadius: 4, endRadius: 120))
                .scaleEffect(1 + (speaking ? 0.25 : level * 0.6))
                .blur(radius: 18)
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(Theme.accent.opacity(live ? 0.35 : 0.1)).interactive(), in: .circle)
                .scaleEffect(1 + level * 0.15)
            Text("my")
                .font(.mono(34, weight: .bold))
                .foregroundStyle(Theme.accentSoft)
        }
        .animation(.smooth(duration: 0.18), value: level)
        .animation(.smooth, value: speaking)
        .accessibilityLabel(live ? "Live voice, tap to hang up" : "Voice")
    }
}
