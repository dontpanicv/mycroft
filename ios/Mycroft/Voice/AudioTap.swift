import AVFoundation
import Foundation

/// Audio taps run on a real-time audio queue. A closure written inside main-actor code would inherit main-actor
/// isolation and trap there ("dispatch_assert_queue"), so tap blocks are made here, outside any actor.
nonisolated enum AudioTap {
    static func block(_ handle: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in handle(buffer) }
    }

    static func completion(_ handle: @escaping @Sendable () -> Void) -> AVAudioNodeCompletionHandler {
        { handle() }
    }

    static func played(_ handle: @escaping @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in handle() }
    }
}
