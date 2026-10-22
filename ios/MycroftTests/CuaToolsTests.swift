import AVFoundation
import Foundation
import ImageIO
import PiDurableKit
import UniformTypeIdentifiers
import Testing

@testable import Mycroft

@Suite("Desktop control")
struct CuaToolsTests {
    /// A small `cua.tools` result in Cua Driver's shape.
    static let catalog = try! CuaTools.Catalog.decode(Data("""
        {"version": "0.38.0", "instructions": "cua-driver: background GUI automation.",
         "tools": [
          {"name": "list_apps", "description": "List apps.", "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
           "annotations": {"readOnlyHint": true, "destructiveHint": false}},
          {"name": "get_window_state", "description": "Snapshot a window.",
           "inputSchema": {"type": "object", "required": ["pid", "window_id"], "properties": {"pid": {"type": "integer"}, "window_id": {"type": "integer"}}},
           "annotations": {"readOnlyHint": true}, "outputSchema": {"type": "object"}, "risk": {"class": "r3"}},
          {"name": "click", "description": "Click.", "inputSchema": {"type": "object", "properties": {"element_token": {"type": "string"}}, "additionalProperties": false},
           "annotations": {"readOnlyHint": false, "destructiveHint": true}},
          {"name": "type_text", "description": "Type.", "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}, "element_token": {"type": "string"}}},
           "annotations": {"destructiveHint": true}},
          {"name": "hotkey", "description": "Keys.", "inputSchema": {"type": "object", "properties": {"keys": {"type": "array", "items": {"type": "string"}}}}},
          {"name": "press_key", "description": "Key.", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "modifiers": {"type": "array", "items": {"type": "string"}}}}},
          {"name": "invoke_menu", "description": "Menu.", "inputSchema": {"type": "object", "properties": {"path": {"type": "array", "items": {"type": "string"}}}}},
          {"name": "run_steps", "description": "Steps.", "inputSchema": {"type": "object", "required": ["steps"], "properties": {"steps": {"type": "array"}}},
           "annotations": {"readOnlyHint": false, "destructiveHint": true}},
          {"name": "kill_app", "description": "Kill.", "inputSchema": {"type": "object", "required": ["pid"], "properties": {"pid": {"type": "integer"}}},
           "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true}},
          {"name": "set_window_frame", "description": "Frame.", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": false}},
          {"name": "parse_visual_regions", "description": "Regions.", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": true}},
          {"name": "history_query", "description": "History.", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": true}}
         ]}
        """.utf8))

    static var entries: [String: CuaTools.Catalog.Entry] {
        Dictionary(uniqueKeysWithValues: catalog.tools.map { ($0.name, $0) })
    }

    static func risk(_ tool: String, _ arguments: JSONObject, index: SnapshotIndex = SnapshotIndex()) -> CuaTools.Risk? {
        CuaTools.risk(entries[tool]!, arguments: arguments, index: index, catalog: entries)
    }

    /// A Mail window as get_window_state reports it: a full markdown read.
    static let mail: JSONValue = [
        "content": [["type": "text", "text": """
            ✅ Mail — window "Inbox" snapshot_id=s0000002a
            element_token for row [N] = s0000002a:N (row [11] is "s0000002a:11")
            - [0] AXWindow "Inbox"
              - [1] AXTextField "To" = "order@example.com"
              - [2] AXButton "Save" [id=save actions=[press]]
              - [3] AXButton "Cancel" [actions=[press]]
              - AXStaticText = "hello"
              - [4] AXButton "Archive" (Move to the archive) [actions=[press]]
              - [11] AXButton "Send" [id=send actions=[press]]
            """]],
        "structuredContent": ["snapshot_id": "s0000002a", "app_name": "Mail", "window_title": "Inbox", "pid": 501, "window_id": 7],
    ]

    @Test func catalogBecomesTools() throws {
        let tools = Dictionary(uniqueKeysWithValues: CuaTools.makeExtension(catalog: Self.catalog).tools.map { ($0.name, $0) })
        #expect(tools["parse_visual_regions"] == nil && tools["history_query"] == nil)
        #expect(tools.count == 10)
        for tool in tools.values {
            let properties = try #require(tool.parameters.json["properties"]?.objectValue)
            #expect(properties["machine"]?["type"] == "string", "\(tool.name)")
            #expect(tool.parameters.json["required"]?.arrayValue?.first == "machine", "\(tool.name)")
            let readOnly = Self.entries[tool.name]!.isReadOnly
            #expect((properties["confirmed"] != nil) == !readOnly, "\(tool.name)")
            #expect(tool.replay == (readOnly ? .safe : .unsafe), "\(tool.name)")
            #expect(tool.deferred == !CuaTools.core.contains(tool.name), "\(tool.name)")
        }
        let window = try #require(tools["get_window_state"]?.parameters.json)
        #expect(window["required"] == ["machine", "pid", "window_id"])
        #expect(tools["click"]?.parameters.json["additionalProperties"] == false)
        #expect(tools["kill_app"]?.deferred == true && tools["set_window_frame"]?.deferred == true)
        // Actions are run_steps' steps: click itself waits for tool_search.
        #expect(tools["run_steps"]?.deferred == false && tools["click"]?.deferred == true)
        #expect(CuaTools.prompt(Self.catalog).hasSuffix("\n\ncua-driver: background GUI automation."))
    }

    /// Cua's tool names must not shadow Mycroft's own tools (a later extension's tool replaces an earlier one).
    @Test func bundledCatalogKeepsClearOfMycroftsTools() throws {
        let catalog = try #require(CuaTools.Catalog.load(cached: URL(filePath: "/nonexistent/cua-tools.json")), "no bundled catalog")
        let own = Set((HandsTools.makeExtension().tools + ShowTools.makeExtension().tools).map(\.name) + ["now", "codemode", "tool_search"])
        let clashes = catalog.tools.map(\.name).filter { own.contains($0) || $0.hasPrefix("self_") || $0.hasPrefix("hands_") }
        #expect(clashes.isEmpty, "\(clashes)")
    }

    @Test func mapsCallToolResults() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let shot = CuaTools.toolResult([
            "content": [["type": "text", "text": "Clicked."], ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/jpeg"]],
            "structuredContent": ["effect": "confirmed"],
        ])
        #expect(shot.output?.first == .text("Clicked."))
        #expect(shot.output?.count == 2, "structured content stays out when there is text")
        guard case .image(let image)? = shot.output?.last else { Issue.record("no image"); return }
        #expect(image.mimeType == "image/jpeg" && image.bytes == png)
        #expect(!shot.isError)

        let structured = CuaTools.toolResult(["content": [], "structuredContent": ["apps": [["name": "Mail", "pid": 501]]]])
        #expect(structured.output == [.text(#"{"apps":[{"name":"Mail","pid":501}]}"#)])

        let failed = CuaTools.toolResult(["content": [["type": "text", "text": "no such window"]], "isError": true])
        #expect(failed.isError && failed.output == [.text("no such window")])
    }

    @Test func destructiveToolsNeedConfirmation() {
        #expect(Self.risk("kill_app", ["machine": "Mac", "pid": 42]) == .init(action: "calling kill_app", reason: "Cua marks kill_app destructive"))
        // Cua marks every input tool destructive; a click is judged by its target, and an unknown one passes.
        #expect(Self.risk("click", ["machine": "Mac", "element_token": "s00000099:4"]) == nil)
        #expect(Self.risk("run_steps", ["steps": [["tool": "kill_app", "args": ["pid": 42]]]])?.reason == "Cua marks kill_app destructive")
    }

    @Test func destructiveWordsInArguments() {
        #expect(Self.risk("type_text", ["text": "Please send the report"]) == .init(action: "typing “Please send the report”", reason: "“send”"))
        #expect(Self.risk("type_text", ["text": "The sender resent it", "session": "send-mail"]) == nil, "whole words, and not session labels")
        #expect(Self.risk("invoke_menu", ["path": ["File", "Move to Trash"]]) == .init(action: "choosing File > Move to Trash", reason: "“trash”"))
        #expect(Self.risk("invoke_menu", ["path": ["Apple", "Shut  Down…"]])?.reason == "“shut down”")
        #expect(Self.risk("run_steps", ["steps": [["tool": "click", "args": ["role": "button", "name": "Send"]]]])?.reason == "“send”")
        #expect(Self.risk("run_steps", ["steps": [["click": ["role": "button", "name": "Delete"]]]])?.action == "running these steps")
        #expect(Self.risk("run_steps", ["steps": [["click": ["name": "Next"], "expect": ["text": "Order placed"]]],
                                        "observe": ["query": "Send"]]) == nil, "reads and expectations are not actions")
    }

    @Test func targetsAreNamedFromTheLatestRead() {
        var index = SnapshotIndex()
        index.record(Self.mail)
        #expect(Self.risk("click", ["element_token": "s0000002a:11"], index: index) == .init(action: "clicking “Send” in Mail", reason: "“send”"))
        #expect(Self.risk("click", ["element_token": "s0000002a:2"], index: index) == nil)
        #expect(Self.risk("click", ["element_token": "s0000002a:1"], index: index) == nil, "a field's value is the user's content")
        #expect(index.target("s0000002a:4")?.row == .init(role: "AXButton", title: "Archive", detail: "Move to the archive"))
        #expect(Self.risk("run_steps", ["steps": [["tool": "click", "args": ["element_token": "s0000002a:11"]]]], index: index)?.action
            == "clicking “Send” in Mail")
        #expect(Self.risk("type_text", ["text": "Hello", "element_token": "s0000002a:11"], index: index)?.reason == "“send”")
    }

    /// run_steps' end read is a diff against the last read: it is merged into that snapshot.
    @Test func diffsMergeIntoTheirSnapshot() {
        var index = SnapshotIndex()
        index.record(Self.mail)
        index.record([
            "content": [["type": "text", "text": "1. click ok"], ["type": "text", "text": """
                since s0000002a: 1 added, 0 changed, 1 removed. Use element_tokens s0000002b:N for + and ~ rows and unchanged rows; - ids are from s0000002a.
                + [3] AXButton "Delete" [actions=[press]]
                - [1] AXTextField "To" = "order@example.com"
                reindexed: [3-4] -> [4-5]
                """]],
            "structuredContent": ["steps": [], "observation": ["ok": true, "state": [
                "snapshot_id": "s0000002b", "since": "s0000002a", "since_status": "diff", "app_name": "Mail",
            ]]],
        ])
        #expect(Self.risk("click", ["element_token": "s0000002b:3"], index: index)?.action == "clicking “Delete” in Mail")
        #expect(index.target("s0000002b:4")?.row.name == "Cancel")
        #expect(index.target("s0000002b:5")?.row.name == "Archive")
        #expect(index.target("s0000002b:2")?.row.name == "Save")
        #expect(index.target("s0000002b:11")?.row.name == "Send")
        #expect(index.target("s0000002b:1") == nil)
        #expect(index.target("s0000002a:3")?.row.name == "Cancel", "the base snapshot stays as it was")

        // No change: the new snapshot has the old rows. Text only, no structured content.
        index.record(["content": [["type": "text", "text": "snapshot_id=s0000002c\nno change since s0000002b. Rows and indices are as before."]]])
        #expect(index.target("s0000002c:3")?.row.name == "Delete")
        #expect(index.target("s0000002c:3")?.app == "Mail")
    }

    @Test func keysThatQuitOrDelete() {
        #expect(Self.risk("hotkey", ["keys": ["cmd", "q"]]) == .init(action: "pressing cmd+q", reason: "“cmd+q”"))
        #expect(Self.risk("hotkey", ["keys": ["shift", "command", "Delete"]])?.action == "pressing shift+cmd+delete")
        #expect(Self.risk("press_key", ["key": "backspace", "modifiers": ["cmd"]])?.action == "pressing cmd+delete")
        #expect(Self.risk("press_key", ["key": "cmd+q"]) != nil)
        #expect(Self.risk("run_steps", ["steps": [["tool": "hotkey", "args": ["keys": ["cmd", "q"]]]]]) != nil)
        #expect(Self.risk("hotkey", ["keys": ["cmd", "s"]]) == nil)
        #expect(Self.risk("press_key", ["key": "delete"]) == nil, "fixing a typo is fine")
    }

    @Test func confirmationIsStrippedBeforeCua() async {
        let catalog = Self.entries
        let confirmed = await CuaTools.confirm(ToolCall(id: "1", name: "kill_app", arguments: ["machine": "test-mac", "pid": 42, "confirmed": true]), catalog: catalog)
        guard case .rewrite(let arguments) = confirmed else { Issue.record("not rewritten: \(confirmed)"); return }
        #expect(arguments == ["machine": "test-mac", "pid": 42])

        let asked = await CuaTools.confirm(ToolCall(id: "2", name: "kill_app", arguments: ["machine": "test-mac", "pid": 42]), catalog: catalog)
        guard case .block(let message) = asked else { Issue.record("not blocked: \(asked)"); return }
        #expect(message.hasPrefix("Stopped before calling kill_app: it looks irreversible (Cua marks kill_app destructive)."))
        #expect(message.hasSuffix("call kill_app again with the same arguments and confirmed: true."))

        let harmless = await CuaTools.confirm(ToolCall(id: "3", name: "click", arguments: ["machine": "test-mac", "x": 3, "y": 4, "confirmed": false]), catalog: catalog)
        guard case .rewrite(let clicked) = harmless else { Issue.record("not rewritten: \(harmless)"); return }
        #expect(clicked["confirmed"] == nil)

        guard case .allow = await CuaTools.confirm(ToolCall(id: "4", name: "list_apps", arguments: ["machine": "test-mac"]), catalog: catalog) else {
            Issue.record("a read was stopped")
            return
        }
    }

    @Test func newerCatalogWins() throws {
        let folder = URL.temporaryDirectory.appending(path: "cua-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundled = folder.appending(path: "bundled.json"), cached = folder.appending(path: "cached.json")
        func write(_ version: String, _ instructions: String, to url: URL) throws {
            try Data(#"{"version": "\#(version)", "instructions": "\#(instructions)", "tools": []}"#.utf8).write(to: url)
        }
        try write("0.38.0", "bundled", to: bundled)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "bundled", "no cache yet")
        try write("0.39.0", "cached", to: cached)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "cached")
        try write("0.38.10", "cached", to: cached)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "cached", "numeric order")
        try write("0.38.0", "cached", to: cached)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "bundled", "a tie goes to the app's own")
        try write("0.37.2", "cached", to: cached)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "bundled", "an app update brought a newer one")
        try Data("{".utf8).write(to: cached)
        #expect(CuaTools.Catalog.load(cached: cached, bundled: bundled)?.instructions == "bundled")
    }
}

@Suite("Dictation")
struct FluidSpeechTests {
    /// Runs the bundled Fluid Speech Mini on a clip made with `say`. It runs in the Simulator too, on the CPU there.
    @Test(.enabled(if: FluidSpeech.isBundled, "this build has no Fluid Speech Mini"), .timeLimit(.minutes(5)))
    func fluidSpeechTranscribesAClip() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "speech", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == FluidSpeech.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        var started = Date.now
        try await FluidSpeech.shared.load()
        let loading = Date.now.timeIntervalSince(started)
        started = .now
        let text = try await FluidSpeech.shared.transcribe(samples).lowercased()
        print("fluid speech: \(text) (loading \(loading) s, transcribing \(Date.now.timeIntervalSince(started)) s)")
        #expect(text.contains("server"))
        #expect(text.contains("mac"))
    }
}

private final class BundleToken {}

@Suite("Show")
struct ShowToolsTests {
    /// A big PNG comes back as a JPEG the screen can take (under 600 KB of base64), at most 2000 px on its long side.
    @Test func encodesAnyImageSmallEnoughForTheScreen() throws {
        let width = 3000, height = 1800
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Noise, the worst case for compression.
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                     blue: .random(in: 0...1, using: &generator), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
        }
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let picture = try ShowTools.encode(png as Data)
        #expect(max(picture.width, picture.height) <= ShowTools.maxPixels)
        #expect(picture.data.base64EncodedString().count < 600_000)
        #expect(picture.data.starts(with: [0xFF, 0xD8]), "a JPEG")
    }

    @Test func refusesWhatIsNotAnImage() {
        #expect(throws: (any Error).self) { try ShowTools.encode(Data("<html></html>".utf8)) }
    }
}
