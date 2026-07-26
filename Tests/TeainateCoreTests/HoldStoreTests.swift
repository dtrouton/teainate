import Testing
import Foundation
@testable import TeainateCore

private struct FakeSnapshotter: ProcessSnapshotting {
    let table: [pid_t: ProcessSnapshot]
    func snapshot() throws -> [pid_t: ProcessSnapshot] { table }
}

private func table(_ entries: (pid_t, String)...) -> [pid_t: ProcessSnapshot] {
    var result: [pid_t: ProcessSnapshot] = [:]
    for (pid, command) in entries {
        result[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: command)
    }
    return result
}

private func hold(_ id: String, pid: pid_t) -> Hold {
    Hold(
        id: id, kind: .forever, label: nil, source: .cli,
        caffeinatePID: pid, flags: ["-i"], startedAt: Date(timeIntervalSince1970: 0),
        expiresAt: nil, watchedPID: nil, display: false, acOnly: false
    )
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-test-\(UUID().uuidString)")
        .appendingPathComponent("holds.json")
}

@Test func reconcileKeepsLiveCaffeinateHolds() {
    let kept = reconcile([hold("a", pid: 100)], against: table((100, "caffeinate")))
    #expect(kept.map(\.id) == ["a"])
}

@Test func reconcileDropsDeadPIDs() {
    let kept = reconcile([hold("a", pid: 100)], against: table((200, "caffeinate")))
    #expect(kept.isEmpty)
}

@Test func reconcileDropsRecycledPIDs() {
    // PID alive but no longer caffeinate — the number was reused.
    let kept = reconcile([hold("a", pid: 100)], against: table((100, "Safari")))
    #expect(kept.isEmpty)
}

@Test func readOnMissingFileReturnsEmpty() throws {
    let store = HoldStore(fileURL: tempFile(), snapshotter: FakeSnapshotter(table: [:]))
    #expect(try store.read().isEmpty)
}

@Test func mutateThenReadRoundTrips() throws {
    let store = HoldStore(
        fileURL: tempFile(),
        snapshotter: FakeSnapshotter(table: table((100, "caffeinate")))
    )
    try store.mutate { $0.append(hold("a", pid: 100)) }
    #expect(try store.read().map(\.id) == ["a"])
}

@Test func readPersistsReconciliation() throws {
    let url = tempFile()
    let live = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table((100, "caffeinate"))))
    try live.mutate { $0.append(hold("a", pid: 100)) }

    // Same file, but the process is now gone.
    let dead = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: [:]))
    #expect(try dead.read().isEmpty)

    // The stale entry must be gone from disk, not merely filtered on read.
    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(!raw.contains("\"a\""))
}

@Test func corruptFileIsBackedUpAndTreatedAsEmpty() throws {
    let url = tempFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)

    let store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: [:]))
    #expect(try store.read().isEmpty)

    let backup = url.appendingPathExtension("bak")
    #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test func realSpawnedCaffeinateSurvivesReconciliation() throws {
    // Regression test: SystemCaffeinateSpawner execs /usr/bin/caffeinate by absolute
    // path, and `ps -o comm=` reports the executable's path (truncated to its column
    // width) rather than the bare process name for such processes. If the snapshotter
    // ever reads that field instead of `ucomm=`, reconcile's `command == "caffeinate"`
    // check silently fails and every hold we spawn is dropped on the very next read —
    // while the caffeinate process itself keeps running. Fakes can't catch this because
    // they hardcode `command: "caffeinate"`; this test exercises the real spawner and
    // real `ps` together, exactly like reconcile does in production.
    let spawner = SystemCaffeinateSpawner()
    let pid = try spawner.spawn(flags: ["-i", "-t", "30"])
    defer { spawner.terminate(pid: pid) }

    let snapshot = try PSProcessSnapshotter().snapshot()
    #expect(snapshot[pid]?.command == "caffeinate")

    let kept = reconcile([hold("a", pid: pid)], against: snapshot)
    #expect(kept.map(\.id) == ["a"])
}

@Test func concurrentMutationsDoNotLoseWrites() async throws {
    let url = tempFile()
    var live: [pid_t: ProcessSnapshot] = [:]
    for pid in pid_t(1)...pid_t(20) {
        live[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: "caffeinate")
    }
    let store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: live))

    await withTaskGroup(of: Void.self) { group in
        for pid in pid_t(1)...pid_t(20) {
            group.addTask {
                try? store.mutate { $0.append(hold("h\(pid)", pid: pid)) }
            }
        }
    }
    #expect(try store.read().count == 20)
}
