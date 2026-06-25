@preconcurrency import AVFoundation
import Foundation

final class ASRAudioConverterOneShotInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        let nextBuffer = buffer
        buffer = nil
        lock.unlock()

        guard let nextBuffer else {
            outStatus.pointee = .noDataNow
            return nil
        }

        outStatus.pointee = .haveData
        return nextBuffer
    }
}
