import AVFoundation
import Foundation
import Observation

/// One line of a voice conversation: what the user said, what Mycroft said, or a step it took.
struct VoiceLine: Identifiable, Hashable {
    enum Speaker { case user, mycroft, step }
    let id = UUID()
    let speaker: Speaker
    var text: String
}

/// What the voice screen needs from a voice engine: GPT-Live (``VoiceSession``) or on-device (``OnDeviceVoice``).
@MainActor
protocol VoiceEngine: AnyObject, Observable {
    var lines: [VoiceLine] { get }
    var level: Double { get }
    var speaking: Bool { get }
    var isLive: Bool { get }
    var statusText: String { get }
    var failure: String? { get }
    func start(app: AppModel) async
    func stop()
}

/// Hands-free voice that never leaves the phone except for the agent's own work: on-device transcription
/// (``Transcriber``), the request goes to the Voice thread as text, and the answer is read aloud with on-device speech.
@Observable
final class OnDeviceVoice: NSObject, VoiceEngine {
    enum Phase: Equatable {
        case idle, listening, working, speaking
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lines: [VoiceLine] = []
    var level: Double { transcriber.level }
    var speaking: Bool { phase == .speaking }
    var isLive: Bool { phase != .idle && failure == nil }
    var failure: String? { if case .failed(let message) = phase { message } else { nil } }

    var statusText: String {
        switch phase {
        case .idle: "Off"
        case .listening: "Listening · on-device"
        case .working: "Mycroft is working"
        case .speaking: "Mycroft is talking"
        case .failed: "Voice unavailable"
        }
    }

    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var finishedSpeaking: CheckedContinuation<Void, Never>?
    @ObservationIgnored private weak var app: AppModel?

    /// How long a pause ends what the user says.
    static let endOfSpeech: TimeInterval = 1.4

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(app: AppModel) async {
        guard loop == nil else { return }
        self.app = app
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        synthesizer.stopSpeaking(at: .immediate)
        finishedSpeaking?.resume()
        finishedSpeaking = nil
        Task { await transcriber.stop() }
        if failure == nil { phase = .idle }
    }

    private func run() async {
        while !Task.isCancelled, let app {
            phase = .listening
            await transcriber.start()
            if case .failed(let message) = transcriber.state {
                phase = .failed(message)
                return
            }
            let live = VoiceLine(speaker: .user, text: "")
            lines.append(live)
            // Listen until the user pauses after saying something.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                updateLine(live.id, transcriber.text)
                if !transcriber.text.isEmpty, Date.now.timeIntervalSince(transcriber.lastSpeech) > Self.endOfSpeech { break }
            }
            let request = await transcriber.stop()
            guard !Task.isCancelled else { return }
            updateLine(live.id, request)
            guard !request.isEmpty else {
                lines.removeAll { $0.id == live.id }
                continue
            }

            phase = .working
            do {
                let thread = try await app.voiceThread()
                try await app.send(request, to: thread, steer: await app.isBusy(thread), requestId: "voice:\(UUID().uuidString)")
                var reported = Set<String>()
                repeat {
                    try await Task.sleep(for: .milliseconds(800))
                    for step in await app.recentSteps(thread) where reported.insert(step).inserted {
                        lines.append(VoiceLine(speaker: .step, text: step))
                    }
                } while await app.isBusy(thread)
                let answer = await app.lastAnswer(thread) ?? "Done."
                lines.append(VoiceLine(speaker: .mycroft, text: answer))
                phase = .speaking
                await speak(answer)
            } catch is CancellationError {
                return
            } catch {
                lines.append(VoiceLine(speaker: .step, text: "That failed: \(error.localizedDescription)"))
            }
        }
    }

    private func updateLine(_ id: UUID, _ text: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].text = text
    }

    /// Reads the answer aloud with the best installed voice for the user's language.
    private func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: Self.speakable(text))
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        await withCheckedContinuation { continuation in
            finishedSpeaking = continuation
            synthesizer.speak(utterance)
        }
    }

    /// Markdown and code read badly aloud: keep prose, drop code blocks and symbols, cap the length.
    static func speakable(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code on screen) ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return result.count > 700 ? String(result.prefix(700)) + "… The rest is on screen." : result
    }
}

extension OnDeviceVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishedSpeaking?.resume()
            self.finishedSpeaking = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishedSpeaking?.resume()
            self.finishedSpeaking = nil
        }
    }
}
