import CoreGraphics
import Testing
@testable import DesktopCore

@Suite struct KeyStrokeTests {
    @Test(arguments: [
        ("return", 36), ("escape", 53), ("tab", 48), ("space", 49), ("delete", 51), ("up", 126), ("down", 125),
        ("left", 123), ("right", 124), ("pageup", 116), ("pagedown", 121),
    ] as [(String, Int)])
    func specKeyNames(_ name: String, _ code: Int) throws {
        let stroke = try KeyStroke.parse(key: name)
        #expect(stroke.key == .code(CGKeyCode(code)))
        #expect(stroke.modifiers.isEmpty)
        #expect(!stroke.isCharacter)
        #expect(stroke.name == name)
    }

    @Test func functionKeys() throws {
        let codes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (offset, code) in codes.enumerated() {
            #expect(try KeyStroke.parse(key: "f\(offset + 1)").key == .code(code))
            #expect(try KeyStroke.parse(key: "F\(offset + 1)").key == .code(code))
        }
        #expect(throws: DesktopError.self) { try KeyStroke.parse(key: "f13") }
    }

    @Test func aliasesAndSpelling() throws {
        #expect(try KeyStroke.parse(key: "Return").key == .code(36))
        #expect(try KeyStroke.parse(key: "enter").key == .code(36))
        #expect(try KeyStroke.parse(key: "esc").key == .code(53))
        #expect(try KeyStroke.parse(key: "Page Up").key == .code(116))
        #expect(try KeyStroke.parse(key: "page_down").key == .code(121))
        #expect(try KeyStroke.parse(key: "ArrowUp").key == .code(126))
        #expect(try KeyStroke.parse(key: "backspace").key == .code(51))
        #expect(try KeyStroke.parse(key: "  tab ").key == .code(48))
    }

    @Test func singleCharacters() throws {
        let a = try KeyStroke.parse(key: "a")
        #expect(a.key == .code(0))
        #expect(a.modifiers.isEmpty)
        #expect(a.isCharacter)
        #expect(try KeyStroke.parse(key: "z").key == .code(6))
        #expect(try KeyStroke.parse(key: "1").key == .code(18))
        #expect(try KeyStroke.parse(key: "/").key == .code(44))
        let space = try KeyStroke.parse(key: " ")
        #expect(space.key == .code(49))
        #expect(!space.isCharacter)
    }

    @Test func uppercaseAndShiftedSymbolsAddShift() throws {
        let upper = try KeyStroke.parse(key: "A")
        #expect(upper.key == .code(0))
        #expect(upper.modifiers == [.shift])
        let bang = try KeyStroke.parse(key: "!")
        #expect(bang.key == .code(18))
        #expect(bang.modifiers == [.shift])
        let question = try KeyStroke.parse(key: "?", modifiers: ["cmd"])
        #expect(question.key == .code(44))
        #expect(question.modifiers == [.command, .shift])
    }

    @Test func charactersWithoutAKeyAreUnicode() throws {
        let accent = try KeyStroke.parse(key: "é")
        #expect(accent.key == .character("é"))
        #expect(accent.isCharacter)
        #expect(try KeyStroke.parse(key: "€").key == .character("€"))
        // Posted on virtual key 0, so a modifier would turn it into cmd+a and the like.
        #expect(throws: DesktopError.self) { try KeyStroke.parse(key: "é", modifiers: ["cmd"]) }
    }

    @Test func modifiers() throws {
        let stroke = try KeyStroke.parse(key: "z", modifiers: ["cmd", "shift"])
        #expect(stroke.modifiers == [.command, .shift])
        #expect(stroke.flags == [.maskCommand, .maskShift])
        #expect(stroke.name == "cmd+shift+z")
        let all = try KeyStroke.parse(key: "tab", modifiers: ["Command", "option", "alt", "ctrl", "control"])
        #expect(all.modifiers == [.command, .option, .control])
        #expect(all.flags == [.maskCommand, .maskAlternate, .maskControl])
        #expect(all.name == "cmd+option+control+tab")
    }

    @Test func rejects() {
        #expect(throws: DesktopError.invalid("Unknown modifier \"hyper\"; use cmd, shift, option or control.")) {
            try KeyStroke.parse(key: "a", modifiers: ["hyper"])
        }
        for key in ["", "hyper", "ctrl+a", "\n", "\u{7}", "returnn"] {
            #expect(throws: DesktopError.self, "\(key.debugDescription)") { try KeyStroke.parse(key: key) }
        }
    }
}
