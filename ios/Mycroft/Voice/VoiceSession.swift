import AVFoundation
import Foundation
import Observation
import PiDurableKit
import os

/// Live voice through AirPods or the speaker, with GPT-Live doing the talking and Mycroft doing the work.
///
/// GPT-Live runs in client-delegation mode (ADR 0007): when the user asks for something that needs work, it emits
/// `session.delegation.created`. Mycroft turns the user's words since the last delegation into a durable submission
/// in the Voice thread (request id = delegation id, so a retry never submits twice), streams quiet progress back with
/// `session.thinking.append`, and the answer with `session.commentary.append`, which GPT-Live says in its own words.
///
/// Audio and the WebSocket live here in Swift, so the agent's JavaScript can reload itself mid-conversation.
@Observable
final class VoiceSession: VoiceEngine {
    enum State: Equatable {
        case idle, connecting, live
        case failed(String)
    }

    typealias Line = VoiceLine

    private(set) var state: State = .idle
    private(set) var lines: [Line] = []
    /// Microphone level 0…1 for the orb.
    private(set) var level: Double = 0
    private(set) var speaking = false

    var isLive: Bool { state == .live }
    var failure: String? { if case .failed(let message) = state { message } else { nil } }
    var statusText: String {
        switch state {
        case .idle: "Off"
        case .connecting: "Connecting"
        case .live: speaking ? "Mycroft is talking" : "Listening · GPT-Live"
        case .failed: "Voice unavailable"
        }
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// Used only on the audio thread after setup.
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var delegations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "voice")

    static let model = "gpt-live-1"
    static let sampleRate = 24_000.0
    nonisolated(unsafe) private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    // MARK: Lifecycle

    func start(app: AppModel) async {
        guard state != .live, state != .connecting else { return }
        self.app = app
        guard let key = Keychain.read(Secret.openAI) else {
            state = .failed("Live voice needs an OpenAI API key. Add it in Settings.")
            return
        }
        state = .connecting
        do {
            try configureAudio()
            var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            try await send([
                "type": "session.start",
                "session": [
                    "model": Self.model,
                    "instructions": Self.instructions,
                    "audio": ["format": ["type": "audio/pcm", "rate": Int(Self.sampleRate)], "output": ["voice": "marin"]],
                    "delegation": ["type": "client"],
                ],
            ])
            Task { await self.receive() }
        } catch {
            fail(error)
        }
    }

    func stop() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        player.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        level = 0
        speaking = false
        // Delegated work keeps running in its thread; only the conversation ends.
    }

    private func fail(_ error: Error) {
        log.error("voice failed: \(error)")
        stop()
        state = .failed(error.localizedDescription)
    }

    static let instructions = """
        You are the voice of Mycroft, a personal agent that lives on the user's iPhone and can work on their computers. \
        Talk briefly and naturally, like a capable colleague on a call. Delegate anything that needs real work — \
        running commands, reading or changing files, using the user's Mac, looking things up, remembering — and keep \
        the user company while it runs: say what is happening when you get progress, and give the result in one or two \
        sentences when it arrives. Never invent results you were not given.
        """

    // MARK: Audio

    private func configureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)  // echo cancellation, so it doesn't hear itself
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: wireFormat)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat, block: AudioTap.block { [weak self] buffer in
            self?.captured(buffer)
        })
        try engine.start()
        player.play()
    }

    /// Microphone audio (audio thread): convert to 24 kHz mono PCM16 here, then hand plain bytes to the main actor.
    nonisolated private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let audio = Data(bytes: samples[0], count: Int(out.frameLength) * 2).base64EncodedString()
        let rms = Self.rms(buffer)
        Task { @MainActor in
            guard self.state == .live else { return }
            self.level = self.level * 0.6 + min(1, rms * 8) * 0.4
            try? await self.send(["type": "session.input_audio.append", "audio": audio])
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    /// GPT-Live audio: base64 PCM16 LE mono 24 kHz → float buffer → player.
    private func play(_ base64: String) {
        guard let data = Data(base64Encoded: base64), data.count >= 2 else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) { out[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
        }
        speaking = true
        player.scheduleBuffer(buffer, completionHandler: AudioTap.completion { [weak self] in
            Task { @MainActor in
                guard let self, !self.player.isPlaying || self.engine.isRunning else { return }
                self.speaking = false
            }
        })
    }

    // MARK: Events

    private func receive() async {
        while let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                handle(event)
            } catch {
                if state != .idle { fail(error) }
                return
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.started":
            state = .live
        case "session.output_audio.delta":
            if let delta = event["delta"] as? String { play(delta) }
        case "session.input_transcript.delta":
            guard let delta = event["delta"] as? String else { return }
            heard += delta
            append(delta, as: .user)
        case "session.output_transcript.delta":
            if let delta = event["delta"] as? String { append(delta, as: .mycroft) }
        case "session.delegation.created":
            guard let delegation = event["delegation"] as? [String: Any], let id = delegation["id"] as? String else { return }
            delegate(id)
        case "session.closed":
            stop()
        case "error":
            let error = event["error"] as? [String: Any]
            log.error("live error: \(String(describing: error))")
            if let message = error?["message"] as? String { append(message, as: .step) }
        default:
            break
        }
    }

    private func append(_ delta: String, as speaker: VoiceLine.Speaker) {
        if speaker != .step, let last = lines.indices.last, lines[last].speaker == speaker {
            lines[last].text += delta
        } else {
            lines.append(Line(speaker: speaker, text: delta.trimmingCharacters(in: .whitespaces)))
        }
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }

    // MARK: Delegation

    /// Hands what the user asked for to Mycroft and reports back until the run ends.
    private func delegate(_ id: String) {
        let request = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        guard let app, !request.isEmpty else { return }
        delegations[id] = Task {
            do {
                let thread = try await app.voiceThread()
                try await app.send(request, to: thread, steer: await app.isBusy(thread), requestId: "live:\(id)")
                try await sendContext("thinking", id, "Mycroft is working on it.")
                var reported = Set<String>()
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(1200))
                    let steps = await app.recentSteps(thread)
                    for step in steps where !reported.contains(step) {
                        reported.insert(step)
                        append(step, as: .step)
                        try await sendContext("thinking", id, step)
                    }
                    if await !app.isBusy(thread) { break }
                }
                let answer = await app.lastAnswer(thread) ?? "It finished without an answer."
                try await sendContext("commentary", id, String(answer.prefix(1800)))
            } catch {
                try? await sendContext("commentary", id, "That failed: \(error.localizedDescription)")
            }
            delegations[id] = nil
        }
    }

    private func sendContext(_ kind: String, _ delegation: String, _ content: String) async throws {
        try await send(["type": "session.\(kind).append", "delegation_id": delegation, "content": content])
    }

    private func send(_ event: [String: Any]) async throws {
        guard let socket else { return }
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
