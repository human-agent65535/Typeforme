import Combine
import Foundation

@MainActor
final class AudioCoordinator: ObservableObject {
    let recorder = AudioRecorder()
    let keyboardAudioSession = StandbyAudioSession()
    let standbyKeeper = StandbyKeeper()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        recorder.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        keyboardAudioSession.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
