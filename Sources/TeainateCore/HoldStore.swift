import Foundation

public enum HoldStoreError: Error, Equatable {
    case lockTimeout
}

/// Drops holds whose PID is gone, or now belongs to a process that is not `caffeinate`.
/// This is what lets a plain file be a safe source of truth: a stale record can exist
/// after a crash, but never survives the next read.
///
/// This does NOT protect against a PID being recycled by another `caffeinate` process —
/// if a dead hold's PID is reused by an unrelated `caffeinate` (for example, another
/// Claude Code session's), this adopts it as our own. Closing that gap would mean
/// recording and matching the process's start time (`ps -o lstart=`) alongside the PID,
/// which is not implemented here.
public func reconcile(_ holds: [Hold], against table: [pid_t: ProcessSnapshot]) -> [Hold] {
    holds.filter { table[$0.caffeinatePID]?.command == "caffeinate" }
}

public struct HoldStore: Sendable {
    private let fileURL: URL
    private let snapshotter: any ProcessSnapshotting

    public init(fileURL: URL, snapshotter: any ProcessSnapshotting) {
        self.fileURL = fileURL
        self.snapshotter = snapshotter
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
        state.holds = reconcile(state.holds, against: try snapshotter.snapshot())
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
