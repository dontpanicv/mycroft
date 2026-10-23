import Foundation

/// An error that is only its message, for the user or the model to read.
nonisolated struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
