import ActivityKit
import Foundation

enum TypeformeDictationActivityPhase: String, Codable, Hashable, Sendable {
    case ready
    case recording
    case transcribing
    case refining
    case result
    case issue
}

struct TypeformeDictationActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: TypeformeDictationActivityPhase
        var detail: String
        var startedAt: Date?
        var updatedAt: Date
    }

    var sessionID: String
}
