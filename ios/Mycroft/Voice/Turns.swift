import Foundation

/// When the user has finished what they're saying, on the audio's own clock (seconds of audio fed to the recognizer).
///
/// Two signals, because neither is enough alone:
/// - **Loudness.** The microphone level, against a noise floor that follows the room. It drops the moment the user
///   stops, long before the recognizer finalizes its text (which takes 1.5–2 s of audio).
/// - **Words.** When the transcript last gained a word. In a loud room the level never drops, so a longer pause in the
///   words ends the turn instead. Finalizing rewrites the text without adding words, so it never restarts the clock.
///
/// How long a pause ends the turn depends on how the words end: a finished sentence ends quickly, a trailing "and…"
/// or "um" waits.
nonisolated struct TurnDetector: Equatable {
    /// Audio time of the last loud frame, and of the last new word.
    private(set) var lastVoice: Double = 0
    private(set) var lastWords: Double = 0
    private(set) var words = 0
    /// The room's level, followed slowly upwards and at once downwards.
    private(set) var noiseFloor = 0.002

    static let finished = 0.7
    static let unsure = 1.2
    static let trailing = 2.0
    /// A spoken command ("send it") needs only a short pause.
    static let command = 0.5
    /// Without a drop in loudness, the words alone end the turn after this long.
    static let wordsOnly = 2.5

    /// A new turn starts now.
    mutating func reset(at time: Double) {
        lastVoice = time
        lastWords = time
        words = 0
    }

    mutating func heard(_ text: String, at time: Double) {
        let count = Self.count(text)
        if count > words { lastWords = time }
        words = count
    }

    /// One buffer's RMS level.
    mutating func level(_ rms: Double, at time: Double) {
        noiseFloor = rms < noiseFloor ? rms : noiseFloor + (rms - noiseFloor) * 0.002
        if rms > max(noiseFloor * 4, 0.006) { lastVoice = time }
    }

    /// Whether the user is done, at audio time `time`, having said `text`.
    func ended(_ text: String, at time: Double) -> Bool {
        guard words > 0 else { return false }
        let pause = VoiceCommand.parse(text).command != nil ? Self.command : Self.pause(after: text)
        return time - lastVoice >= pause || time - lastWords >= max(pause, Self.wordsOnly)
    }

    /// The pause that ends a turn ending in `text`.
    static func pause(after text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trailing }
        if last == "," || last == "-" || last == "…" { return trailing }
        let word = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map { $0.lowercased() } ?? ""
        if hanging.contains(word) { return trailing }
        if ".?!".contains(last) { return finished }
        return unsure
    }

    /// Words a sentence doesn't end on: the user is still going.
    static let hanging: Set<String> = [
        "and", "or", "but", "so", "because", "then", "if", "that", "which", "who", "when", "while", "to", "of", "for",
        "with", "the", "a", "an", "my", "on", "in", "at", "from", "like", "um", "uh", "er", "hmm", "also", "maybe",
    ]

    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// What the user can say at the end of a turn instead of tapping.
nonisolated enum VoiceCommand: Equatable {
    /// "…send it": send now, without waiting.
    case send
    /// "…scratch that": throw this turn away.
    case clear

    static let phrases: [(String, VoiceCommand)] = [
        ("send it", .send), ("send that", .send), ("send now", .send), ("send the message", .send),
        ("scratch that", .clear), ("cancel that", .clear), ("never mind", .clear), ("nevermind", .clear),
    ]

    /// The text without a trailing command, and the command.
    static func parse(_ text: String) -> (text: String, command: VoiceCommand?) {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let trimmed = text.trimmingCharacters(in: ignored)
        for (phrase, command) in phrases {
            guard let range = trimmed.range(of: phrase, options: [.caseInsensitive, .backwards, .anchored]) else { continue }
            let before = trimmed[..<range.lowerBound]
            // A whole phrase, not the end of a longer word ("resend it").
            guard before.isEmpty || before.last.map({ !$0.isLetter }) == true else { continue }
            return (String(before).trimmingCharacters(in: ignored), command)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}
