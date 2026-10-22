import Foundation

/// A thread's own instructions (the last section of its system prompt): what the moment needs.
nonisolated enum Instructions {
    /// While the user talks with Mycroft in a conversation (Voice/VoiceChat.swift).
    static let voice = """
        The user is talking with you right now: your words are spoken aloud by a speech synthesizer as you write them, \
        and they may not be looking at the screen.
        - Before you use tools, say in one short sentence what you are about to do, so they aren't left in silence.
        - Write the way you'd speak: plain sentences, no Markdown, tables, lists, code blocks or links unless they ask.
        - Keep answers short, one to three sentences, unless they ask for more.
        - Your final answer continues from what you already said in this turn: never repeat it, just add what's new.
        - Their words come from on-device speech recognition and may have sound-alike mistakes.
        """
}
