import Foundation

protocol ASRLivePreviewSession: AnyObject, Sendable {
    var provider: String { get }

    func appendPCM16kMonoFloat32Data(_ data: Data)
    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool
    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool
    func currentTranscript() -> String?
    func terminate(reason: String)
}
