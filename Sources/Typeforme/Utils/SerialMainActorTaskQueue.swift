import Foundation

/// Runs cleanup operations in order and provides a drain barrier that also
/// includes work appended while an earlier operation is still running.
@MainActor
final class SerialMainActorTaskQueue {
    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tail: Tail?

    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let preceding = tail?.task
        let id = UUID()
        let task = Task { [weak self] in
            if let preceding {
                await preceding.value
            }
            await operation()
            self?.clear(id: id)
        }
        tail = Tail(id: id, task: task)
        return task
    }

    func waitForAll() async {
        while let tail {
            await tail.task.value
            if self.tail?.id == tail.id {
                self.tail = nil
            }
        }
    }

    private func clear(id: UUID) {
        if tail?.id == id {
            tail = nil
        }
    }
}
