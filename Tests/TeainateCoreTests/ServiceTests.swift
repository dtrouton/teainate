import Testing
import Foundation
@testable import TeainateCore

private final class RecordingSpawner: CaffeinateSpawning, @unchecked Sendable {
    var spawned: [[String]] = []
    var terminated: [pid_t] = []
    var nextPID: pid_t = 100
    var shouldFail = false

    func spawn(flags: [String]) throws -> pid_t {
        if shouldFail { throw ServiceError.spawnFailed("boom") }
        spawned.append(flags)
        defer { nextPID += 1 }
        return nextPID
    }

    func terminate(pid: pid_t) { terminated.append(pid) }
}

private struct StubSnapshotter: ProcessSnapshotting {
    var table: [pid_t: ProcessSnapshot]
    func snapshot() throws -> [pid_t: ProcessSnapshot] { table }
}

private struct StubAssertions: AssertionReading {
    var value: [ForeignAssertion] = []
    func assertions() throws -> [ForeignAssertion] { value }
}

private func makeService(
    spawner: RecordingSpawner = RecordingSpawner(),
    snapshotter: StubSnapshotter = StubSnapshotter(table: [:]),
    assertions: StubAssertions = StubAssertions(),
    now: Date = Date(timeIntervalSince1970: 1_000_000)
) -> TeainateService {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-svc-\(UUID().uuidString)")
        .appendingPathComponent("holds.json")
    return TeainateService(
        store: HoldStore(fileURL: url, snapshotter: snapshotter),
        spawner: spawner,
        assertionReader: assertions,
        snapshotter: snapshotter,
        now: { now }
    )
}

private func liveTable(_ pids: pid_t...) -> [pid_t: ProcessSnapshot] {
    var table: [pid_t: ProcessSnapshot] = [:]
    for pid in pids {
        table[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: "caffeinate")
    }
    return table
}

@Test func onSpawnsCaffeinateAndRecordsHold() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100)))

    let hold = try service.on(HoldOptions(source: .cli))

    #expect(spawner.spawned == [["-i"]])
    #expect(hold.caffeinatePID == 100)
    #expect(try service.status().holds.map(\.id) == [hold.id])
}

@Test func timedHoldRecordsExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)), now: now)

    let hold = try service.on(HoldOptions(duration: 7200, source: .cli))

    #expect(hold.expiresAt == now.addingTimeInterval(7200))
    #expect(try service.status().holds.first?.remainingSeconds == 7200)
}

@Test func foreverHoldHasNoExpiry() throws {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)))
    #expect(try service.on(HoldOptions(source: .cli)).expiresAt == nil)
}

@Test func failedSpawnRecordsNothing() throws {
    let spawner = RecordingSpawner()
    spawner.shouldFail = true
    let service = makeService(spawner: spawner)

    #expect(throws: ServiceError.self) { try service.on(HoldOptions(source: .cli)) }
    #expect(try service.status().holds.isEmpty)
}

@Test func failedStoreWriteTerminatesSpawnedProcess() throws {
    // Force HoldStore.mutate to fail on its first call (the one made from `on()`'s
    // append) by making the store's own snapshotter throw once. The snapshotter
    // succeeds on later calls, so we can still read the store afterward to confirm
    // nothing was persisted.
    final class FlakySnapshotter: ProcessSnapshotting, @unchecked Sendable {
        var callCount = 0
        let table: [pid_t: ProcessSnapshot]
        init(table: [pid_t: ProcessSnapshot]) { self.table = table }
        func snapshot() throws -> [pid_t: ProcessSnapshot] {
            callCount += 1
            if callCount == 1 { throw ServiceError.spawnFailed("store snapshot boom") }
            return table
        }
    }

    let flaky = FlakySnapshotter(table: liveTable(100))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-svc-\(UUID().uuidString)")
        .appendingPathComponent("holds.json")
    let spawner = RecordingSpawner()
    let service = TeainateService(
        store: HoldStore(fileURL: url, snapshotter: flaky),
        spawner: spawner,
        assertionReader: StubAssertions(),
        snapshotter: StubSnapshotter(table: liveTable(100)),
        now: { Date(timeIntervalSince1970: 1_000_000) }
    )

    #expect(throws: (any Error).self) { try service.on(HoldOptions(source: .cli)) }
    #expect(spawner.terminated == [100])
    #expect(try service.status().holds.isEmpty)
}

@Test func multipleHoldsCoexist() throws {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100, 101)))
    _ = try service.on(HoldOptions(source: .menu))
    _ = try service.on(HoldOptions(source: .claude))
    #expect(try service.status().holds.count == 2)
}

@Test func offByIDTerminatesOnlyThatHold() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100, 101)))
    let first = try service.on(HoldOptions(source: .menu))
    _ = try service.on(HoldOptions(source: .cli))

    let released = try service.off(id: first.id)

    #expect(released.map(\.id) == [first.id])
    #expect(spawner.terminated == [100])
    #expect(try service.status().holds.count == 1)
}

@Test func offWithNilIDReleasesEverything() throws {
    let spawner = RecordingSpawner()
    let service = makeService(spawner: spawner, snapshotter: StubSnapshotter(table: liveTable(100, 101)))
    _ = try service.on(HoldOptions(source: .menu))
    _ = try service.on(HoldOptions(source: .cli))

    #expect(try service.off(id: nil).count == 2)
    #expect(spawner.terminated == [100, 101])
    #expect(try service.status().holds.isEmpty)
}

@Test func awakeReflectsWhetherHoldsExist() throws {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)))
    #expect(try service.status().awake == false)
    _ = try service.on(HoldOptions(source: .cli))
    #expect(try service.status().awake == true)
}

@Test func statusIncludesForeignAssertions() throws {
    let foreign = ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")
    let service = makeService(assertions: StubAssertions(value: [foreign]))
    #expect(try service.status().foreignAssertions == [foreign])
}

@Test func statusSurvivesAssertionReaderFailure() throws {
    struct Failing: AssertionReading {
        func assertions() throws -> [ForeignAssertion] { throw ServiceError.spawnFailed("pmset") }
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-\(UUID().uuidString)/holds.json")
    let service = TeainateService(
        store: HoldStore(fileURL: url, snapshotter: StubSnapshotter(table: [:])),
        spawner: RecordingSpawner(),
        assertionReader: Failing(),
        snapshotter: StubSnapshotter(table: [:]),
        now: { Date() }
    )
    // Degrades partially: own holds still reported, foreign list empty.
    #expect(try service.status().foreignAssertions.isEmpty)
}

@Test func resolveSessionPIDFindsClaudeAncestor() throws {
    var table = liveTable()
    table[getpid()] = ProcessSnapshot(pid: getpid(), parentPID: 500, command: "swift-testing")
    table[500] = ProcessSnapshot(pid: 500, parentPID: 400, command: "zsh")
    table[400] = ProcessSnapshot(pid: 400, parentPID: 1, command: "claude")
    let service = makeService(snapshotter: StubSnapshotter(table: table))

    #expect(try service.resolveSessionPID() == 400)
}

@Test func resolveSessionPIDThrowsWhenNoClaudeAncestor() throws {
    var table: [pid_t: ProcessSnapshot] = [:]
    table[getpid()] = ProcessSnapshot(pid: getpid(), parentPID: 1, command: "swift-testing")
    let service = makeService(snapshotter: StubSnapshotter(table: table))

    #expect(throws: ServiceError.noClaudeAncestor) { try service.resolveSessionPID() }
}

@Test func statusEncodesSnakeCaseJSON() throws {
    let service = makeService(snapshotter: StubSnapshotter(table: liveTable(100)))
    _ = try service.on(HoldOptions(duration: 60, label: "test", source: .claude))
    let data = try Status.encoder.encode(try service.status())
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"foreign_assertions\""))
    #expect(json.contains("\"remaining_seconds\""))
    #expect(json.contains("\"expires_at\""))
}
