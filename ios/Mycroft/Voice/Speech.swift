import Foundation

// What conversation mode (VoiceChat) says and hears, worked out from text alone. Tested in VoiceTests.

/// A run's text as sentences to say aloud, each once.
///
/// While a run streams, its text only grows: the answer being written is committed as an entry in the same place,
/// and the next message comes after it. So what has been handed to speech is a count of characters, and each update
/// says what comes after it, a whole sentence at a time. A new user message (the user's turn, or a steer) starts a new
/// run of text.
nonisolated struct Narration: Equatable {
    /// The user message the text answers.
    private(set) var anchor: String?
    /// Characters of the text handed to speech (or skipped).
    private(set) var said = 0
    private var text = ""
    /// Inside a fenced code block: its lines aren't read.
    private var inCode = false
    /// The user cut in: nothing more is said until their next message.
    private var silent = false

    /// The text of a run after `anchor`: its text blocks in order, the last one still being written while
    /// `streaming`. Returns the new sentences to say.
    mutating func update(anchor: String?, pieces: [String], streaming: Bool) -> [String] {
        if anchor != self.anchor {
            self.anchor = anchor
            said = 0
            inCode = false
            silent = false
        }
        text = pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard said < text.count else { return [] }
        let (lines, consumed) = Self.sentences(in: String(text.dropFirst(said)), final: !streaming)
        said += consumed
        if silent { return [] }
        return lines.compactMap { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                return nil
            }
            return inCode ? nil : SpokenText.of(line)
        }
    }

    /// Treats everything so far as said: the user cut in, or the conversation started in the middle of a run.
    mutating func skip(anchor: String?, pieces: [String]) {
        _ = update(anchor: anchor, pieces: pieces, streaming: false)
    }

    /// The user cut in: what is left of this run isn't said. The next user message (theirs, or a steer) starts again.
    mutating func skip() {
        said = text.count
        silent = true
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "*", "_"]
    /// Words a full stop follows without ending the sentence.
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "no", "approx"]

    /// Whole sentences and lines at the start of `text`, and how many characters they took. A sentence ends at a line
    /// break or at a full stop, question or exclamation mark followed by a space; the rest waits for more text unless
    /// `final`.
    static func sentences(in text: String, final: Bool) -> ([String], Int) {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0
        func emit(through end: Int) {
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            start = end
        }
        while index < characters.count {
            let character = characters[index]
            if character.isNewline {
                emit(through: index + 1)
            } else if terminators.contains(character) {
                var end = index + 1
                while end < characters.count, closers.contains(characters[end]) || terminators.contains(characters[end]) { end += 1 }
                // Whether a space follows isn't known yet: wait for more text.
                guard end < characters.count else { break }
                if characters[end].isWhitespace, endsSentence(characters, before: index, from: start) {
                    emit(through: end)
                    index = end
                    continue
                }
            }
            index += 1
        }
        if final { emit(through: characters.count) }
        return (sentences, start)
    }

    /// Whether the mark at `index` ends a sentence: not after an abbreviation, a single letter ("J. R. R."), or a list
    /// number at the start of a line ("1. ").
    private static func endsSentence(_ characters: [Character], before index: Int, from start: Int) -> Bool {
        guard characters[index] == "." else { return true }
        var wordStart = index
        while wordStart > start, !characters[wordStart - 1].isWhitespace { wordStart -= 1 }
        let word = String(characters[wordStart..<index]).lowercased()
        if word.count == 1, word.first?.isLetter == true { return false }
        if abbreviations.contains(word) { return false }
        let before = String(characters[start..<wordStart]).trimmingCharacters(in: .whitespaces)
        if before.isEmpty, !word.isEmpty, word.allSatisfy(\.isNumber) { return false }
        return true
    }
}

/// Markdown and symbols as they should be read aloud.
nonisolated enum SpokenText {
    /// One sentence or line of Markdown as words to say, or nil when there is nothing to say (a table row, a rule,
    /// only symbols).
    static func of(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") || trimmed.allSatisfy({ "-*_=|: ".contains($0) }) { return nil }
        var text = trimmed
        // Headings, quotes, list markers.
        text = text.replacing(/^(?:#{1,6}|>+|[-*+•]|\d{1,3}[.)])\s+/, with: "")
        // Images and links say their text; bare links are just "a link".
        text = text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        text = text.replacing(/https?:\/\/\S+/, with: "a link")
        text = text.replacing(/`([^`]*)`/) { String($0.1) }
        // Emphasis.
        text = text.replacing(/\*\*|__|~~|\*/, with: "")
        text = String(text.filter { character in
            !character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        })
        text = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }
}

/// When the user has finished speaking: how long a pause after their words ends their turn.
nonisolated enum TurnEnd {
    /// Words people trail off on mid-thought.
    private static let unfinished: Set<String> = [
        "and", "but", "or", "so", "because", "um", "uh", "er", "like", "the", "a", "an", "to", "of", "with", "then",
    ]

    /// Seconds of quiet after `words`: short after a finished sentence, long after "and…", "um" or a comma.
    static func pause(after words: String) -> Double {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return .infinity }
        if last == "," || last == "-" || last == "…" { return 2.0 }
        let lastWord = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map { $0.lowercased() } ?? ""
        if unfinished.contains(lastWord) { return 2.0 }
        if ".!?".contains(last) { return 0.8 }
        return 1.2
    }
}

/// Mycroft's own voice coming back through the microphone, as far as echo cancellation leaves any.
nonisolated enum Echo {
    /// Words that cut Mycroft off on their own.
    private static let interruptions: Set<String> = ["stop", "wait", "pause", "quiet", "enough", "mycroft", "hold"]

    /// Whether `heard` is only what Mycroft `said` (or too little to cut it off for): it takes two words, most of
    /// them not Mycroft's, or one of the interruptions.
    static func isEcho(_ heard: String, of said: String) -> Bool {
        let words = Self.words(heard)
        guard !words.isEmpty else { return true }
        if words.contains(where: interruptions.contains) { return false }
        guard words.count >= 2 else { return true }
        let saidWords = Set(Self.words(said))
        let fresh = words.filter { !saidWords.contains($0) }
        return Double(fresh.count) < Double(words.count) * 0.5
    }

    /// Whether `heard` asks Mycroft to stop (on the speaker, where nothing else can be told from its echo): one of the
    /// interruptions, and not one Mycroft is saying itself.
    static func interrupts(_ heard: String, of said: String) -> Bool {
        let saidWords = Set(words(said))
        return words(heard).contains { interruptions.contains($0) && !saidWords.contains($0) }
    }

    /// Lowercased words, with typographic apostrophes as plain ones: Mycroft writes "I’ll", the recognizer "I'll".
    private static func words(_ text: String) -> [String] {
        text.lowercased().replacing(/[’‘]/, with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
}
