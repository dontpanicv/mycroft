import PiDurableKit
import SwiftUI
import Testing

@testable import Mycroft

@Suite("Activity summaries")
struct ActivitySummaryTests {
    @Test func describesHandsCommandsWithTheirMachine() {
        let step = ActivitySummary.describe(tool: "hands_exec", arguments: ["command": "cargo build --release", "machine": "hetzner"])
        #expect(step.headline == "Running `cargo build --release` on hetzner")
        #expect(step.machine == "hetzner")
        #expect(step.kind == .command)
    }

    @Test func describesDesktopActions() {
        let step = ActivitySummary.describe(
            tool: "ui_act", arguments: ["action": "click", "target": "Save", "app": "Notes", "machine": "Mac"])
        #expect(step.headline == "Click “Save” in Notes on Mac")
        #expect(step.kind == .desktop)
    }

    @Test func clipsLongCommandsToOneLine() {
        let step = ActivitySummary.describe(
            tool: "hands_exec", arguments: ["command": "echo first line\necho second", "machine": "box"])
        #expect(step.headline == "Running `echo first line` on box")
    }

    @Test func closingGroupsWorkByMachine() {
        let steps = [
            ActivitySummary.describe(tool: "hands_exec", arguments: ["command": "make", "machine": "hetzner"]),
            ActivitySummary.describe(tool: "hands_exec", arguments: ["command": "make test", "machine": "hetzner"]),
            ActivitySummary.describe(tool: "hands_edit", arguments: ["path": "src/main.rs", "machine": "hetzner"]),
            ActivitySummary.describe(tool: "ui_act", arguments: ["action": "click", "target": "OK", "machine": "Mac"]),
            ActivitySummary.describe(tool: "self_read", arguments: ["path": "extension.js"]),
            ActivitySummary.describe(tool: "self_activate", arguments: ["note": "x"]),
        ]
        #expect(ActivitySummary.closing(steps) == "1 desktop step on Mac · 2 commands, 1 file edit on hetzner · 1 step on the phone · rewrote itself")
    }

    @Test func closingCountsEveryPhoneStep() {
        let steps = ["self_status", "self_read", "now", "self_read"].map { ActivitySummary.describe(tool: $0, arguments: [:]) }
        #expect(ActivitySummary.closing(steps) == "4 steps on the phone")
        #expect(ActivitySummary.closing([]) == "Answered")
    }
}

@Suite("Appearance")
struct AppearanceTests {
    @Test func parsesHex() {
        let rgba = Color.components(hex: "#1F6F3A")
        #expect(rgba?.0 == Double(0x1F) / 255 && rgba?.3 == 1)
        #expect(Color.components(hex: "#1F6F3A80")?.3 == Double(0x80) / 255)
        #expect(Color.components(hex: "1F6F3A") == nil)
    }
}
