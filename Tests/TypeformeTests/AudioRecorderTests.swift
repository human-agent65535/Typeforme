import AVFoundation
import Testing
@testable import Typeforme

@Suite("AudioRecorder")
struct AudioRecorderTests {
    @Test func acceptsSupportedMicrophoneFormats() throws {
        try AudioInputFormatValidator.validate(
            sampleRate: 48_000,
            channelCount: 2,
            commonFormat: .pcmFormatFloat32
        )
        try AudioInputFormatValidator.validate(
            sampleRate: 16_000,
            channelCount: 1,
            commonFormat: .pcmFormatInt16
        )
    }

    @Test func rejectsUnavailableOrMalformedMicrophoneFormats() {
        #expect(throws: AudioRecorderError.self) {
            try AudioInputFormatValidator.validate(
                sampleRate: 0,
                channelCount: 1,
                commonFormat: .pcmFormatFloat32
            )
        }
        #expect(throws: AudioRecorderError.self) {
            try AudioInputFormatValidator.validate(
                sampleRate: 48_000,
                channelCount: 0,
                commonFormat: .pcmFormatFloat32
            )
        }
        #expect(throws: AudioRecorderError.self) {
            try AudioInputFormatValidator.validate(
                sampleRate: .infinity,
                channelCount: 1,
                commonFormat: .pcmFormatFloat32
            )
        }
        #expect(throws: AudioRecorderError.self) {
            try AudioInputFormatValidator.validate(
                sampleRate: 48_000,
                channelCount: 1,
                commonFormat: .otherFormat
            )
        }
    }

    @Test func audioLevelSupportsFloatAndInt16MicrophoneFormats() throws {
        let floatFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let floatBuffer = try #require(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 4))
        floatBuffer.frameLength = 4
        for channelIndex in 0..<2 {
            for frameIndex in 0..<4 {
                floatBuffer.floatChannelData?[channelIndex][frameIndex] = 0.25
            }
        }

        let int16Format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let int16Buffer = try #require(AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 4))
        int16Buffer.frameLength = 4
        for frameIndex in 0..<4 {
            int16Buffer.int16ChannelData?[0][frameIndex] = Int16.max / 4
        }

        let floatLevel = normalizedAudioRMS(floatBuffer)
        let int16Level = normalizedAudioRMS(int16Buffer)
        #expect(floatLevel > 0)
        #expect(int16Level > 0)
        #expect(abs(floatLevel - int16Level) < 0.001)
    }

    @Test func audioLevelIncludesEveryInterleavedChannel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let samples = try #require(buffer.int16ChannelData?[0])
        samples[0] = 0
        samples[1] = Int16.max
        samples[2] = 0
        samples[3] = Int16.max

        #expect(normalizedAudioRMS(buffer) > 0.9)
    }

    @Test func captureQueueIsBoundedByPCMBytesAndAudioDuration() throws {
        let standard = try AudioCaptureQueuePlan.make(
            sampleRate: 48_000,
            channelCount: 2,
            commonFormat: .pcmFormatFloat32
        )
        let highChannelCount = try AudioCaptureQueuePlan.make(
            sampleRate: 96_000,
            channelCount: 8,
            commonFormat: .pcmFormatFloat32
        )
        let extreme = try AudioCaptureQueuePlan.make(
            sampleRate: 192_000,
            channelCount: 32,
            commonFormat: .pcmFormatFloat32
        )

        for plan in [standard, highChannelCount, extreme] {
            #expect(plan.totalBytes <= AudioCaptureQueuePlan.maximumQueuedPCMBytes)
            #expect(plan.bufferedDuration <= AudioCaptureQueuePlan.maximumBufferedDuration)
            #expect(plan.bufferCount <= AudioCaptureQueuePlan.maximumBufferCount)
        }
        #expect(standard.bufferCount == 30)
        #expect(highChannelCount.bufferCount == 30)
        #expect(extreme.bufferCount == 6)
        #expect(extreme.totalBytes == 14_745_600)
    }

    @Test func discardDropsBacklogAndWaitsOnlyForOwnedBuffer() {
        var state = AudioCapturePipelineState()
        state.readIndex = 4
        state.writeIndex = 1
        state.queuedCount = 5
        state.workerOwnsReadBuffer = true

        #expect(state.requestDiscard() == 4)
        #expect(!state.accepting)
        #expect(state.cancelRequested)
        #expect(state.queuedCount == 1)
        #expect(state.readIndex == 4)
        #expect(!state.isReadyToTerminate)

        state.releaseReadBuffer(bufferCount: 8)

        #expect(state.queuedCount == 0)
        #expect(state.readIndex == state.writeIndex)
        #expect(!state.workerOwnsReadBuffer)
        #expect(state.isReadyToTerminate)
    }

    @Test func discardWithoutOwnedBufferIsImmediatelyTerminal() {
        var state = AudioCapturePipelineState()
        state.readIndex = 2
        state.writeIndex = 5
        state.queuedCount = 3

        #expect(state.requestDiscard() == 3)
        #expect(state.queuedCount == 0)
        #expect(state.readIndex == state.writeIndex)
        #expect(state.isReadyToTerminate)
    }
}
