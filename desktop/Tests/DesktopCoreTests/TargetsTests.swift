import Foundation
import Testing
@testable import DesktopCore

@Suite struct TargetsTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func webAddresses() throws {
        #expect(try Targets.webURL("https://example.com/a?b=c").absoluteString == "https://example.com/a?b=c")
        #expect(try Targets.webURL("http://example.com").absoluteString == "http://example.com")
        #expect(try Targets.webURL("example.com/page").absoluteString == "https://example.com/page")
        #expect(try Targets.webURL("localhost:3000").absoluteString == "https://localhost:3000")
        #expect(try Targets.webURL(" HTTPS://Example.com ").host == "Example.com")
    }

    @Test func refusesOtherSchemes() {
        for text in ["file:///etc/hosts", "javascript:alert(1)", "mailto:a@b.c", "ssh://host", "x-apple.systempreferences:com.apple.preference",
                     "vnc://host", "", "https://", "two words.com"] {
            #expect(throws: DesktopError.self, "\(text)") { try Targets.webURL(text) }
        }
    }

    @Test func folders() throws {
        #expect(try Targets.folderURL("~", home: home).path == "/Users/someone")
        #expect(try Targets.folderURL("~/Projects/x", home: home).path == "/Users/someone/Projects/x")
        #expect(try Targets.folderURL("Desktop", home: home).path == "/Users/someone/Desktop")
        #expect(try Targets.folderURL("documents", home: home).path == "/Users/someone/Documents")
        #expect(try Targets.folderURL("Downloads", home: home).path == "/Users/someone/Downloads")
        #expect(try Targets.folderURL("Home", home: home).path == "/Users/someone")
        #expect(try Targets.folderURL("Applications", home: home).path == "/Applications")
        #expect(try Targets.folderURL("/tmp/../var", home: home).path == "/var")
        #expect(try Targets.folderURL("Documents/Receipts", home: home).path == "/Users/someone/Documents/Receipts")
        #expect(throws: DesktopError.self) { try Targets.folderURL("", home: home) }
        #expect(throws: DesktopError.self) { try Targets.folderURL("~other/x", home: home) }
    }

    @Test func socketPaths() {
        #expect(Paths.defaultSocket(environment: ["HANDS_STATE_DIR": "/tmp/state"], home: home) == "/tmp/state/desktop.sock")
        #expect(Paths.defaultSocket(environment: [:], home: home) == "/Users/someone/Library/Application Support/hands/desktop.sock")
        #expect(Paths.defaultSocket(environment: ["HANDS_STATE_DIR": ""], home: home) == "/Users/someone/Library/Application Support/hands/desktop.sock")
    }
}
