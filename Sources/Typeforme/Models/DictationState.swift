import Foundation

enum DictationState: String, Sendable, CustomStringConvertible {
    case idle
    case recording
    case transcribing
    case correcting
    case inserting
    case success
    case error

    var description: String { rawValue }
}
