import Foundation

public enum HoldStoreError: Error, Equatable {
    case lockTimeout
}

public let caffeinateProcessName = "caffeinate"
/// The watcher is the CLI binary itself, so `ucomm` reports the executable's name.
public let watcherProcessName = "teainate"

/// The `ucomm` a live hold's recorded pid must carry to still be ours.
public func expectedProcessName(for hold: Hold) -> String {
    hold.lidClosed ? watcherProcessName : caffeinateProcessName
}

/// Drops holds whose PID is gone, now belongs to a process of the wrong kind, or —
/// when the record carries a start time — to a process started at a different instant.
/// A record without a start time (written before 0.2.1) matches by name only.
/// This is what lets a plain file be a safe source of truth: a stale record can exist
/// after a crash, but never survives the next read.
public func reconcile(
    _ holds: [Hold],
    against table: [pid_t: ProcessSnapshot],
    startTime: (pid_t) -> ProcessStartTime? = { _ in nil }
) -> [Hold] {
    holds.filter { hold in
        guard table[hold.caffeinatePID]?.command == expectedProcessName(for: hold) else { return false }
        guard let recorded = hold.processStartedAt else { return true }
        return startTime(hold.caffeinatePID) == recorded
    }
}

/// Every pid teainate is responsible for: the hold processes themselves plus the
/// caffeinate child of each lid-closed watcher. Without the children, a watcher's own
/// caffeinate would be listed — and reclaimable — as "not managed by teainate".
public func ownedPIDs(of holds: [Hold], in table: [pid_t: ProcessSnapshot]) -> Set<pid_t> {
    var owned = Set(holds.map(\.caffeinatePID))
    let watchers = Set(holds.filter(\.lidClosed).map(\.caffeinatePID))
    for entry in table.values
    where entry.command == caffeinateProcessName && watchers.contains(entry.parentPID) {
        owned.insert(entry.pid)
    }
    return owned
}

public struct HoldStore: Sendable {
    private let fileURL: URL
    private let snapshotter: any ProcessSnapshotting
    private let startTimes: any ProcessStartTimeReading

    public init(
        fileURL: URL, snapshotter: any ProcessSnapshotting,
        startTimes: any ProcessStartTimeReading = ProcPIDInfoStartTimeReader()
    ) {
        self.fileURL = fileURL
        self.snapshotter = snapshotter
        self.startTimes = startTimes
    }

    public func read() throws -> [Hold] {
        try readState().holds
    }

    public func readState() throws -> StoreState {
        try mutateState { $0 }
    }

    /// Holds-only view for callers that do not care about the lid-closed marker.
    public func mutate<T>(_ body: (inout [Hold]) throws -> T) throws -> T {
        try mutateState { try body(&$0.holds) }
    }

    /// Reconciles, applies `body`, and persists — all under an exclusive lock so the
    /// app, the CLI and every watcher cannot interleave a read-modify-write.
    public func mutateState<T>(_ body: (inout StoreState) throws -> T) throws -> T {
        try ensureDirectoryExists()
        let descriptor = try acquireLock()
        defer { flock(descriptor, LOCK_UN); close(descriptor) }

        var state = loadRaw()
        state.holds = reconcile(
            state.holds, against: try snapshotter.snapshot(), startTime: startTimes.startTime(of:)
        )
        let result = try body(&state)
        try persist(state)
        return result
    }

    // MARK: - Internals

    private var lockURL: URL { fileURL.appendingPathExtension("lock") }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    /// Locks a sibling `.lock` file rather than the state file itself, because
    /// persisting replaces the state file's inode.
    private func acquireLock() throws -> Int32 {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw HoldStoreError.lockTimeout }

        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(descriptor)
                throw HoldStoreError.lockTimeout
            }
            usleep(20_000)
        }
        return descriptor
    }

    private func loadRaw() -> StoreState {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return StoreState() }
        do {
            return try Hold.decoder.decode(StoreState.self, from: data)
        } catch {
            // Never crash over a bad file: preserve it for diagnosis and start clean.
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return StoreState()
        }
    }

    private func persist(_ state: StoreState) throws {
        let data = try Hold.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
