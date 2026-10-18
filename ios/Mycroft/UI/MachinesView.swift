import SwiftUI

/// Settings → Machines: the paired computers and the one-line install.
struct MachinesSection: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    /// Machine name → nil while checking, "online", or why it can't be reached.
    @State private var status: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.machines) { machine in
                VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(machine.name).font(.mono(14, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("\(machine.displayOS) · \(machine.arch) · \(machine.hosts.first ?? "?"):\(machine.port)")
                            .font(.mono(10.5)).foregroundStyle(Theme.inkFaint)
                    }
                    Spacer()
                    switch status[machine.name] {
                    case "online": Tag(text: "Online", color: Theme.success)
                    case nil: ProgressView().controlSize(.mini).tint(Theme.accentSoft)
                    default: Tag(text: "Offline", color: Theme.danger)
                    }
                }
                if let problem = status[machine.name], problem != "online" {
                    Text(problem).font(.mono(10.5)).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .contextMenu {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        Task { try? await app.removeMachine(machine) }
                    }
                }
            }
            if app.machines.isEmpty {
                Text("Pair a Mac or a Linux machine to give Mycroft a shell, files, long jobs and desktop control.")
                    .font(.grotesk(14)).foregroundStyle(Theme.inkMuted)
                    .padding(.bottom, 12)
            }
            Button {
                adding = true
            } label: {
                MonoLabel("Add machine", color: .white, size: 12).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 12)
            .accessibilityIdentifier("addMachine")
        }
        .hairlineCard(padding: 12)
        .sheet(isPresented: $adding) {
            AddMachineSheet()
        }
        .task(id: app.machines) { await check() }
    }

    /// Connects to every paired machine and shows whether it answers.
    private func check() async {
        status = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for machine in app.machines {
                group.addTask {
                    do {
                        _ = try await HandsPool.shared.connection(to: machine)
                        return (machine.name, "online")
                    } catch {
                        return (machine.name, error.localizedDescription)
                    }
                }
            }
            for await (name, result) in group { status[name] = result }
        }
    }
}

/// Shows the install command (already on the clipboard) and waits for the machine to pair back.
struct AddMachineSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = InstallServer()
    @State private var copied = false
    @State private var localNetwork: LocalNetworkPermission.Status?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                switch server.state {
                case .starting:
                    ProgressView().tint(Theme.accentSoft)
                case .failed(let message):
                    Text(message).font(.mono(12)).foregroundStyle(Theme.danger).hairlineCard()
                case .waiting:
                    waiting
                case .paired(let machine):
                    paired(machine)
                }
                Spacer()
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .canvasBackground(grid: true)
            .navigationTitle("Add machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task {
            // Ask iOS for local-network access first: until it is granted, the computer's download is refused.
            localNetwork = await LocalNetworkPermission.request(wait: 4)
            server.start { machine in try await app.addMachine(machine) }
        }
        .onChange(of: server.command) {
            guard !server.command.isEmpty else { return }
            UIPasteboard.general.string = server.command
            copied = true
        }
        .onDisappear { server.stop() }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 18) {
            if localNetwork == .denied {
                Text("iOS is blocking Mycroft from your local network, so the computer can't reach this phone. Turn on Settings → Privacy & Security → Local Network → Mycroft, then come back.")
                    .font(.grotesk(14)).foregroundStyle(Theme.danger).hairlineCard(padding: 10)
            }
            step("01", "Open Terminal on your Mac or Linux machine.", "It must be on the same Wi-Fi as this iPhone.")
            step("02", "Paste and press Return.", copied ? "The command is on your clipboard. With Universal Clipboard, just paste on the Mac." : "")
            Text(server.command)
                .font(.mono(11))
                .foregroundStyle(Theme.accentSoft)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hairlineCard(padding: 12, fill: Theme.raised)
                .accessibilityIdentifier("installCommand")
            HStack {
                Button("Copy again", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = server.command
                    copied = true
                }
                .buttonStyle(.glass)
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.accentSoft)
                    MonoLabel("Waiting for the machine", size: 10)
                }
            }
            Text("Keep this screen open while it installs. The command works once, for 10 minutes, and only talks to this iPhone.")
                .font(.grotesk(13)).foregroundStyle(Theme.inkFaint)
        }
    }

    private func paired(_ machine: Machine) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoLabel("Paired", color: Theme.success)
            Text(machine.name).font(.mono(26, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("pairedName")
            Text("\(machine.displayOS) \(machine.arch) · hands \(machine.version)").font(.mono(12)).foregroundStyle(Theme.inkMuted)
            Text("Mycroft can now run commands, edit files and start long jobs there. Mention it by name in a thread.")
                .font(.grotesk(15)).foregroundStyle(Theme.inkMuted)
            Button {
                dismiss()
            } label: {
                MonoLabel("Done", color: .white, size: 12).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number).font(.mono(11)).foregroundStyle(Theme.accentSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.grotesk(16, weight: .semibold)).foregroundStyle(Theme.ink)
                if !detail.isEmpty { Text(detail).font(.grotesk(14)).foregroundStyle(Theme.inkMuted) }
            }
        }
    }
}
