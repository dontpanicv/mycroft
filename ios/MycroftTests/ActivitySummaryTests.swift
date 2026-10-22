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
        let step = ActivitySummary.describe(tool: "type_text", arguments: ["text": "hello from Mycroft", "pid": 501, "machine": "Mac"])
        #expect(step.headline == "Typing “hello from Mycroft” on Mac")
        #expect(step.kind == .desktop)
        #expect(ActivitySummary.describe(tool: "hotkey", arguments: ["keys": ["cmd", "n"], "machine": "Mac"]).headline == "Pressing cmd+n on Mac")
        #expect(ActivitySummary.describe(tool: "invoke_menu", arguments: ["path": ["File", "New Note"], "machine": "Mac"]).headline
            == "Choosing File > New Note on Mac")
        #expect(ActivitySummary.describe(tool: "run_steps", arguments: ["steps": [["tool": "click"], ["tool": "type_text"]], "machine": "Mac"]).headline
            == "Running 2 steps in an app on Mac")
        #expect(ActivitySummary.describe(tool: "get_window_state", arguments: ["pid": 501, "window_id": 7, "machine": "Mac"]).headline
            == "Looking at a window on Mac")
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
            ActivitySummary.describe(tool: "click", arguments: ["element_token": "s0000002a:3", "machine": "Mac"]),
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
