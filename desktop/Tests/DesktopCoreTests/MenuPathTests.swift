import Testing
@testable import DesktopCore

@Suite struct MenuPathTests {
    @Test func parsesTheSpecForm() throws {
        let path = try MenuPath.parse("File > New Note")
        #expect(path.components == ["File", "New Note"])
        #expect(path.description == "File > New Note")
    }

    @Test func parsesOtherSeparatorsAndSpacing() throws {
        #expect(try MenuPath.parse("Format›Font›Bold").components == ["Format", "Font", "Bold"])
        #expect(try MenuPath.parse("  View → Enter Full Screen ").components == ["View", "Enter Full Screen"])
        #expect(try MenuPath.parse("Edit>Find>Find…").components == ["Edit", "Find", "Find…"])
    }

    @Test func roundTripsAvailableMenus() throws {
        for text in ["File > New Note", "Format > Font > Bold", "Window > Zoom"] {
            #expect(try MenuPath.parse(text).description == text)
        }
    }

    @Test func rejectsIncompletePaths() {
        for text in ["", "File", "File >", "> New", "File >  > New", "   "] {
            #expect(throws: DesktopError.self, "\(text)") { try MenuPath.parse(text) }
        }
    }

    @Test func normalizesTitles() {
        #expect(MenuPath.normalize("Save As…") == "save as")
        #expect(MenuPath.normalize("Save As...") == "save as")
        #expect(MenuPath.normalize("  Show   Sidebar ") == "show sidebar")
    }

    @Test func matchesExactBeforeNormalized() {
        let titles = ["Save…", "Save As…", "save"]
        #expect(MenuPath.match("save", in: titles) == 2)
        #expect(MenuPath.match("Save", in: titles) == 0)
        #expect(MenuPath.match("save as...", in: titles) == 1)
        #expect(MenuPath.match("Export", in: titles) == nil)
    }
}
