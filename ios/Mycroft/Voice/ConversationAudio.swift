import AVFoundation
import Foundation
import Observation
import os

/// A conversation's audio (``VoiceChat``), in the listener's engine: Mycroft's voice plays through the engine that
/// records, with echo cancellation on the speaker (none with headphones), and it switches when they come or go.
///
/// The ``Listener`` makes one for each conversation, and calls it as its audio starts and stops.
@Observable
final class ConversationAudio {
    /// The voice that plays through the listener's engine.
    let speaker: Speaker
    /// What Mycroft says is taken out of what the microphone hears (with headphones nothing comes back to take out).
    /// Without it the conversation doesn't listen while Mycroft speaks.
    private(set) var echoCancelled = false

    /// The listener's engine, which it replaces on each restart.
    @ObservationIgnored private let currentEngine: () -> AVAudioEngine
    private var engine: AVAudioEngine { currentEngine() }
    /// Starts the listener's audio again, on a new route; false if it failed (and the listener stopped).
    @ObservationIgnored private let restart: () -> Bool
    /// The route the audio is set up for: headphones (no echo cancellation) or the speaker.
    @ObservationIgnored private var setUpForHeadphones = false
    @ObservationIgnored private var routeChanges: NSObjectProtocol?
    @ObservationIgnored private var rerouting: Task<Void, Never>?
    /// When the audio last restarted for a new route.
    @ObservationIgnored private var reroutes: [Date] = []
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "listener")

    init(speaker: Speaker, engine: @escaping () -> AVAudioEngine, restart: @escaping () -> Bool) {
        self.speaker = speaker
        self.currentEngine = engine
        self.restart = restart
    }

    /// Headphones are connected (wired, AirPods, a car), so the microphone doesn't hear Mycroft. Told by the devices,
    /// not by where the sound goes now: that depends on how the audio is set up (with echo cancellation, iOS names the
    /// AirPods while it plays on the speaker; set up for the AirPods, it can name the speaker), and judging by it made a
    /// conversation switch between the two every second.
    static var headphones: Bool {
        let session = AVAudioSession.sharedInstance()
        let outputs: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .carAudio]
        let inputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .bluetoothLE, .carAudio]
        return session.currentRoute.outputs.contains { outputs.contains($0.portType) }
            || (session.availableInputs ?? []).contains { inputs.contains($0.portType) }
    }

    /// The route's ports, for the journal.
    static var route: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let names = { (ports: [AVAudioSessionPortDescription]) in ports.map(\.portType.rawValue).joined(separator: ",") }
        return "in \(names(route.inputs)), out \(names(route.outputs))"
    }

    // MARK: Audio

    /// Sets the session up, before the engine starts. The microphone stays on while Mycroft speaks, so the user can
    /// cut in: Mycroft's voice must be taken out of what it hears. The system's echo-cancelled input where the route has
    /// it, otherwise voice processing (a call's processing, which also cancels echo). With headphones nothing comes
    /// back to cancel.
    func setUp(_ session: AVAudioSession) throws {
        #if targetEnvironment(simulator)
        // The Simulator's audio server times out (and aborts the app) on echo cancellation and voice processing: the
        // composer's setup, and no cutting in.
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        echoCancelled = false
        setUpForHeadphones = Self.headphones
        log.notice("conversation audio: no echo cancellation in the Simulator")
        #else
        if engine.inputNode.isVoiceProcessingEnabled { try engine.inputNode.setVoiceProcessingEnabled(false) }
        if session.prefersEchoCancelledInput { try? session.setPrefersEchoCancelledInput(false) }
        echoCancelled = false
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        // Headphones: nothing comes back to cancel. Echo cancellation would also take the sound off them: it can't play
        // to AirPods' music profile, so iOS moves Mycroft's voice to the iPhone's speaker (while still reporting the
        // AirPods), where the microphone hears it. Nor does dictation's measurement mode suit: with the iPhone's own
        // microphone, it too moves the sound to the speaker. So the default mode, which leaves it on the headphones.
        setUpForHeadphones = Self.headphones
        if setUpForHeadphones {
            log.notice("conversation audio: headphones, no echo cancellation")
            return
        }
        if session.isEchoCancelledInputAvailable {
            try? session.setPrefersEchoCancelledInput(true)
            try session.setActive(true)
            // A preference, not a guarantee: the route decides.
            if session.isEchoCancelledInputEnabled {
                echoCancelled = true
                log.notice("conversation audio: echo-cancelled input")
                return
            }
            try? session.setPrefersEchoCancelledInput(false)
        }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            echoCancelled = true
            log.notice("conversation audio: voice processing")
        } catch {
            log.error("conversation audio: no echo cancellation (\(error))")
        }
        #endif
    }

    /// The voice plays through the engine: before it starts.
    func connect() {
        speaker.connect(to: engine)
    }

    /// The engine started: the voice can play, and the route is watched.
    func started() {
        do {
            try speaker.player.playAudio()
        } catch {
            log.error("conversation audio: the voice can't play (\(error))")
        }
        guard routeChanges == nil else { return }
        routeChanges = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    /// The conversation's audio ends: the voice stops, and the microphone is left without echo cancellation.
    func stop() {
        if let routeChanges { NotificationCenter.default.removeObserver(routeChanges) }
        routeChanges = nil
        rerouting?.cancel()
        rerouting = nil
        speaker.stop()
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        let session = AVAudioSession.sharedInstance()
        if session.prefersEchoCancelledInput { try? session.setPrefersEchoCancelledInput(false) }
        echoCancelled = false
    }

    // MARK: Routes

    /// Headphones came or went: echo cancellation has to go on or off, and the engine restart with it. Route changes
    /// come in bursts (and setting the session up makes its own), so it settles first.
    private func routeChanged() {
        rerouting?.cancel()
        rerouting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.reroute()
        }
    }

    private func reroute() {
        let headphones = Self.headphones
        guard headphones != setUpForHeadphones else { return }
        // Restarting changes the route too: if that keeps asking for another restart, stay as it is.
        reroutes = reroutes.filter { $0 > .now - 10 } + [.now]
        guard reroutes.count <= 3 else {
            if reroutes.count == 4 { Journal.note("talk_route_loop", ["headphones": "\(headphones)", "route": Self.route]) }
            return
        }
        log.notice("conversation audio: route changed, headphones: \(headphones)")
        Journal.note("talk_route", ["headphones": "\(headphones)", "route": Self.route, "running": "\(engine.isRunning)"])
        // What Mycroft was saying starts again on the new route, from the sentence it was in.
        let unsaid = speaker.halt()
        guard restart() else { return }
        for sentence in unsaid { speaker.say(sentence) }
    }
}
