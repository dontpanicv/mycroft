import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MycroftActivityBundle: WidgetBundle {
    var body: some Widget {
        RunActivityWidget()
    }
}

/// A Mycroft run on the Lock Screen and in the Dynamic Island, in the app's console style.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            LockScreenRun(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.canvas)
                .activitySystemActionForegroundColor(Theme.accentSoft)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Glyph()
                        PhaseLabel(state: state)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: state).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.headline)
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        ForEach(state.recent.prefix(2), id: \.self) { line in
                            Text("· " + line).font(.mono(11)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                        }
                        Tags(attributes: context.attributes, state: state)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Glyph()
            } compactTrailing: {
                if state.isFinished {
                    Image(systemName: state.phase == .done ? "checkmark" : "xmark")
                        .foregroundStyle(state.phase == .done ? Theme.success : Theme.danger)
                } else if let machine = state.machine {
                    Text(machine.prefix(6).uppercased()).font(.mono(11, weight: .semibold)).foregroundStyle(Theme.accentSoft)
                } else {
                    Text(String(format: "%02d", state.step)).font(.mono(12, weight: .semibold)).foregroundStyle(Theme.accentSoft)
                }
            } minimal: {
                Glyph()
            }
            .keylineTint(Theme.accent)
        }
    }
}

private struct LockScreenRun: View {
    let attributes: RunActivityAttributes
    let state: RunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Glyph()
                    PhaseLabel(state: state)
                }
                Spacer()
                Elapsed(state: state)
            }
            Text(state.headline)
                .font(.mono(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if !state.recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.recent.prefix(2), id: \.self) { line in
                        Text("· " + line).font(.mono(11)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    }
                }
            }
            Tags(attributes: attributes, state: state)
        }
        .padding(16)
    }
}

private struct Glyph: View {
    var body: some View {
        Text("my")
            .font(.mono(13, weight: .bold))
            .foregroundStyle(Theme.accentSoft)
    }
}

private struct PhaseLabel: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        MonoLabel(label, color: state.phase == .failed ? Theme.danger : Theme.inkMuted, size: 10)
    }

    private var label: String {
        switch state.phase {
        case .thinking: "Thinking"
        case .working: "Working"
        case .writing: "Answering"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

private struct Elapsed: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        Group {
            if let ended = state.endedAt {
                Text(Duration.seconds(ended.timeIntervalSince(state.startedAt)).formatted(.time(pattern: .minuteSecond)))
            } else {
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .font(.mono(12))
        .monospacedDigit()
        .foregroundStyle(Theme.inkMuted)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 64, alignment: .trailing)
    }
}

private struct Tags: View {
    let attributes: RunActivityAttributes
    let state: RunActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Tag(text: state.machine ?? "Phone", color: state.machine == nil ? Theme.inkMuted : Theme.accentSoft)
            Tag(text: "Step \(String(format: "%02d", state.step))")
            Tag(text: "Gen \(state.generation)")
            Text(attributes.threadTitle).font(.mono(10)).foregroundStyle(Theme.inkFaint).lineLimit(1)
        }
    }
}
