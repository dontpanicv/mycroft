import PiDurableKit
import SwiftUI

/// The glass capsule at the bottom of a thread: model chip, text, send / steer / stop, voice.
struct Composer: View {
    @Binding var text: String
    let busy: Bool
    var focused: FocusState<Bool>.Binding
    let model: ModelRef?
    let send: () -> Void
    let stop: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Tag(text: model?.modelId ?? "default model", color: Theme.inkMuted)
                    Tag(text: "Phone", color: Theme.inkMuted)
                    if busy { Tag(text: empty ? "Running" : "Steer", color: Theme.accentSoft) }
                }
                .padding(.leading, 6)
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(busy ? "Steer the run…" : "Message Mycroft", text: $text, axis: .vertical)
                        .font(.grotesk(16))
                        .lineLimit(1...6)
                        .focused(focused)
                        .accessibilityIdentifier("composer")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    if busy && empty {
                        Button(action: stop) {
                            Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold)).frame(width: 46, height: 46)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("stop")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).frame(width: 46, height: 46)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(empty)
                        .accessibilityLabel(busy ? "Steer" : "Send")
                        .accessibilityIdentifier("send")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
