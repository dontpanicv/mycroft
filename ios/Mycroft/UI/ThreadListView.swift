import SwiftUI

struct ThreadListView: View {
    @Environment(AppModel.self) private var app
    @Binding var path: [ThreadMeta]
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if app.signIn == .signedOut {
                    SignInPrompt().padding(.horizontal, Theme.gutter).padding(.bottom, 18)
                }
                ForEach(app.notices, id: \.self) { notice in
                    Text(notice).font(.mono(11)).foregroundStyle(Theme.accentSoft)
                        .hairlineCard(padding: 10)
                        .padding(.horizontal, Theme.gutter).padding(.bottom, 10)
                }
                if app.threads.isEmpty {
                    EmptyThreads()
                } else {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    ForEach(Array(app.threads.enumerated()), id: \.element.id) { index, thread in
                        NavigationLink(value: thread) {
                            ThreadRow(index: index + 1, thread: thread)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Archive", systemImage: "archivebox") {
                                Task { try? await app.archive(thread) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .canvasBackground(grid: app.threads.isEmpty)
        .overlay(alignment: .bottomTrailing) {
            Button {
                Task {
                    creating = true
                    defer { creating = false }
                    if let thread = try? await app.newThread() { path.append(thread) }
                }
            } label: {
                Image(systemName: creating ? "ellipsis" : "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(creating)
            .accessibilityLabel("New thread")
            .accessibilityIdentifier("newThread")
            .padding(Theme.gutter)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                MonoLabel("Mycroft", color: Theme.ink, size: 13)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Text("Brain on the phone.\n").foregroundStyle(Theme.accentSoft))\(Text("Hands everywhere.").foregroundStyle(Theme.ink))")
                .font(.mono(26, weight: .semibold))
                .tracking(-1.2)
            HStack(spacing: 8) {
                Tag(text: "Gen \(app.generation.active)", color: Theme.accentSoft)
                Tag(text: app.signIn == .signedIn ? "Sol 6.1" : "Signed out",
                    color: app.signIn == .signedIn ? Theme.inkMuted : Theme.danger)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }
}

private struct ThreadRow: View {
    let index: Int
    let thread: ThreadMeta

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", index))
                .font(.mono(11))
                .foregroundStyle(Theme.accentSoft)
            VStack(alignment: .leading, spacing: 5) {
                Text(thread.title)
                    .font(.mono(15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(thread.updatedAt, format: .relative(presentation: .named))
                        .font(.grotesk(13))
                        .foregroundStyle(Theme.inkMuted)
                    Tag(text: thread.machine ?? "Phone")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

private struct EmptyThreads: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MonoLabel("How it works")
            step("01", "Start a thread.", "Each one is a durable conversation that survives iOS killing the app.")
            step("02", "Let it work.", "Leave the app; the run keeps going in the background and shows its progress.")
            step("03", "Let it grow.", "Mycroft can rewrite its own code and reload without losing the conversation.")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(number).font(.mono(11)).foregroundStyle(Theme.accentSoft)
            Text("\(Text(title + " ").foregroundStyle(Theme.ink).fontWeight(.semibold))\(Text(detail).foregroundStyle(Theme.inkMuted))")
                .font(.grotesk(15))
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
