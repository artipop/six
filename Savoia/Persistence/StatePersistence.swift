import Foundation
import Observation

/// Autosave: reads the snapshot under observation tracking, so any change to anything the snapshot
/// touches (a tab's URL, a column moving, a chat line) schedules a save; the writes are debounced and
/// done off the main thread. `flush()` writes synchronously — for the way out.
@MainActor
final class StatePersistence<Store: SnapshotStore> {
    static var debounce: Duration { .seconds(1) }

    private let store: Store
    private let snapshot: @MainActor () -> Store.Snapshot
    private var pending: Task<Void, Never>?
    private var isDirty = false

    init(store: Store, snapshot: @escaping @MainActor () -> Store.Snapshot) {
        self.store = store
        self.snapshot = snapshot
    }

    func start() {
        observe()
    }

    /// Writes now, on the caller's thread. The app calls this on termination.
    func flush() {
        pending?.cancel()
        pending = nil
        write(snapshot())
    }

    private func observe() {
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            guard let self else { return }
            // Fires before the mutation lands; by the time the task runs the new value is in place.
            Task { @MainActor in
                self.scheduleSave()
                self.observe()
            }
        }
    }

    private func scheduleSave() {
        isDirty = true
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self, self.isDirty else { return }
            self.isDirty = false
            let snapshot = self.snapshot()
            let store = self.store
            await Task.detached(priority: .utility) { Self.write(snapshot, to: store) }.value
        }
    }

    private func write(_ snapshot: Store.Snapshot) {
        isDirty = false
        Self.write(snapshot, to: store)
    }

    nonisolated private static func write(_ snapshot: Store.Snapshot, to store: Store) {
        do {
            try store.save(snapshot)
        } catch {
            Log.error(.storage, "save failed (\(Store.Snapshot.self)): \(error)")
        }
    }
}
