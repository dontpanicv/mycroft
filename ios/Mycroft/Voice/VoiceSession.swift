import Foundation

/// The phone's dictation and conversation: one for the app, as there is one microphone and one speaker. A
/// conversation outlives the page that started it (a new generation's screen picks it up), and a preview of the screen
/// never touches it.
final class VoiceSession {
    static let shared = VoiceSession()

    let listener = Listener()
    private(set) lazy var talk = VoiceChat(listener: listener)
}
