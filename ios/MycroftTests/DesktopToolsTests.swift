import AVFoundation
import Foundation
import Testing

@testable import Mycroft

@Suite("Desktop control")
struct DesktopToolsTests {
    /// A Notes window as hands-desktop would report it (docs/desktop-protocol.md).
    static let notes: [String: Any] = [
        "observation": "o-1", "application": "Notes", "window": "Notes", "otherWindows": 0,
        "elements": [
            ["ref": "e1", "index": 1, "role": "button", "label": "New Note", "place": "toolbar", "operations": ["press"]],
            ["ref": "e2", "index": 2, "role": "text field", "label": "Search", "value": "", "place": "toolbar", "operations": ["type", "focus"]],
            ["ref": "e3", "index": 3, "role": "row", "label": "Shopping list", "place": "sidebar", "operations": ["select"]],
        ],
        "available": ["apps": ["Notes", "Safari"], "folders": ["Desktop"], "sites": [], "menus": ["File > New Note"]],
    ]

    @Test func buildsCycleInputFromAnObservation() throws {
        let observation = DesktopTools.Observation(Self.notes)
        let goal = "create a new note saying hello world"
        let (state, operations, heads) = DesktopTools.cycleInput(
            goal: goal, words: goal.split(separator: " ").map(String.init), observation: observation, recent: [])
        #expect(state.elements.count == 3)
        #expect(operations["PRESS"] != nil && operations["TYPE_TEXT"] != nil && operations["MENU"] != nil)
        #expect(operations["OPEN_URL"] == nil)
        #expect(heads["press_target"]?["e1"] == "1. button “New Note” · toolbar")
        #expect(heads["type_target"]?.keys.sorted() == ["e2"])
        #expect(heads["type_from"]?["w5"] == "6: hello")
        let body = try JSONSerialization.jsonObject(with: try JevClient.cycleBody(state: state, operations: operations, heads: heads)) as? [String: Any]
        #expect(body?["model"] as? String == "jev-latest")
        #expect((body?["questions"] as? [String: Any])?.keys.contains("finishes") == true)
    }

    @Test func mapsJevAnswersToActions() throws {
        let observation = DesktopTools.Observation(Self.notes)
        let words = "create a new note saying hello world".split(separator: " ").map(String.init)
        let decision = try JSONDecoder().decode(JevClient.Decision.self, from: Data("""
            {"answers": {
              "operation": {"type": "choice", "choice": "TYPE_TEXT", "confidence": 0.9},
              "type_from": {"type": "choice", "choice": "w5", "confidence": 0.9},
              "type_to": {"type": "choice", "choice": "w6", "confidence": 0.9},
              "type_target": {"type": "choice", "choice": "e2", "confidence": 0.8}
            }}
            """.utf8))
        let action = try #require(DesktopTools.action(for: "TYPE_TEXT", decision: decision, observation: observation, words: words))
        #expect(action.operation == "TYPE_TEXT")
        #expect(action.fields["text"] as? String == "hello world")
        #expect(action.fields["ref"] as? String == "e2")

        let press = try JSONDecoder().decode(JevClient.Decision.self, from: Data("""
            {"answers": {"press_target": {"type": "choice", "choice": "e3", "confidence": 0.9}}}
            """.utf8))
        #expect(DesktopTools.action(for: "PRESS", decision: press, observation: observation, words: words)?.operation == "SELECT")
    }

    @Test func findsSitesInGoals() {
        #expect(DesktopTools.sitesMentioned(in: "open github.com/kurkavojtech and https://example.org") == ["github.com/kurkavojtech", "https://example.org"])
    }

    /// Calls the real Jev API with the synthetic Notes screen: checks the key and the request format. Nothing is
    /// performed anywhere. Needs MYCROFT_LIVE=1 and the Jev key in the app's keychain (scripts/dev-run.sh).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYCROFT_LIVE"] == "1"))
    func jevChoosesTheNextStep() async throws {
        let key = try #require(Keychain.read(Secret.jev), "no Jev key in the keychain")
        let observation = DesktopTools.Observation(Self.notes)
        let goal = "create a new note saying hello world"
        let (state, operations, heads) = DesktopTools.cycleInput(
            goal: goal, words: goal.split(separator: " ").map(String.init), observation: observation, recent: [])
        let decision = try await JevClient.cycle(state: state, operations: operations, heads: heads, apiKey: key)
        let operation = try #require(decision.choice("operation"))
        print("Jev chose \(operation.id) (\(operation.confidence)); press_target \(decision.choice("press_target")?.id ?? "-"); finishes \(decision.noul("finishes"))")
        #expect(operations.keys.contains(operation.id))
    }
}

@Suite("On-device speech")
struct TranscriberTests {
    /// Runs Apple's on-device speech model on a clip made with `say` (downloads the model on first run).
    /// Device only: the Simulator has no on-device speech models ("Model not available").
    @Test(.enabled(if: !isSimulator, "the Simulator has no on-device speech models"), .timeLimit(.minutes(5)))
    func transcribesAClip() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "speech", withExtension: "wav"))
        let text = try await Transcriber.transcribe(file: url).lowercased()
        print("transcribed: \(text)")
        #expect(text.contains("server"))
        #expect(text.contains("mac"))
    }

    /// Runs the bundled Parakeet model on the same clip. It runs in the Simulator too, on the CPU there.
    @Test(.enabled(if: Parakeet.isBundled, "this build has no Parakeet model"), .timeLimit(.minutes(5)))
    func parakeetTranscribesAClip() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "speech", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == Parakeet.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        let started = Date.now
        let text = try await Parakeet.shared.transcribe(samples).lowercased()
        print("parakeet: \(text) (\(Date.now.timeIntervalSince(started)) s, loading included)")
        #expect(text.contains("server"))
        #expect(text.contains("mac"))
    }
}

private final class BundleToken {}

nonisolated private var isSimulator: Bool {
    #if targetEnvironment(simulator)
        true
    #else
        false
    #endif
}
