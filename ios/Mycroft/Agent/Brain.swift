import Foundation
import FoundationModels
import PiDurableKit

/// The model new threads think with, chosen in Settings, kept in UserDefaults. A thread keeps the model it started
/// with.
nonisolated enum Brain: String, Sendable {
    /// Sol 6.1 through the ChatGPT subscription (`openai-codex`).
    case sol
    /// Apple's on-device Foundation Model, as an experiment: no sign-in and no network, but a small context window, so
    /// it gets Mycroft's own extension only (no machines, desktop, self-editing or code mode).
    case apple

    static let key = "mycroft.brain"

    static var saved: Brain {
        UserDefaults.standard.string(forKey: key).flatMap(Brain.init) ?? .sol
    }

    /// A new thread's agent.
    var agent: AgentChange {
        switch self {
        case .sol:
            AgentChange(model: Provider.defaultModel, thinkingLevel: .medium)
        case .apple:
            AgentChange(
                model: .appleOnDevice, thinkingLevel: .low, extensions: .only(["mycroft"]),
                instructions: Instructions.compose(apple: true, voice: false))
        }
    }

    /// Why Apple's model can't answer on this iPhone now, or nil when it can.
    static var appleUnavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This iPhone can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to use it."
        case .unavailable(.modelNotReady): "Apple's model is still downloading."
        case .unavailable: "Apple's model isn't available right now."
        }
    }

    /// The on-device model's context window, in tokens.
    static var appleContextWindow: Int { SystemLanguageModel.default.contextSize }
}

/// A thread's own instructions (the last section of its system prompt): what the model or the moment needs.
nonisolated enum Instructions {
    static let apple = """
        In this thread you run on Apple's on-device model, as an experiment. You have no machines, desktop control or \
        self-editing here, only the tools you are given. If the user asks for something that needs them, say it needs a \
        thread on Sol.
        """

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

    static func compose(apple: Bool, voice: Bool) -> String? {
        let parts = [apple ? Self.apple : nil, voice ? Self.voice : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
