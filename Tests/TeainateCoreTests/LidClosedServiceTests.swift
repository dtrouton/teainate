import Testing
import Foundation
@testable import TeainateCore

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var value = false
    var setCount = 0
    var clearCount = 0
    var failSet = false
    var failClear = false
    func set() throws {
        if failSet { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        setCount += 1; value = true
    }
    func clear() throws {
        if failClear { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        clearCount += 1; value = false
    }
    func isSet() throws -> Bool { value }
}

private struct FakeGrant: PrivilegeGranting {
    var granted = true
    func isGranted() -> Bool { granted }
}

private struct StubBattery: BatteryReading {
    var state: BatteryState? = BatteryState(source: .ac, percent: 90)
    func read() throws -> BatteryState? { state }
}

private final class RecordingWatcherSpawner: WatcherSpawning, @unchecked Sendable {
    var launches: [(URL, [String])] = []
    var nextPID: pid_t = 100
    var shouldFail = false
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        if shouldFail { throw ServiceError.spawnFailed("boom") }
        launches.append((executable, arguments))
        defer { nextPID += 1 }
        return nextPID
    }
}

private final class RecordingSpawner: CaffeinateSpawning, @unchecked Sendable {
    var terminated: [pid_t] = []
    func spawn(flags: [String]) throws -> pid_t { 500 }
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

private struct Rig {
    let flag = FakeFlag()
    let watcher = RecordingWatcherSpawner()
    let spawner = RecordingSpawner()
    let stateFile: URL
    let settings: SettingsStore
    let service: TeainateService

    init(grant: Bool = true, battery: BatteryState? = BatteryState(source: .ac, percent: 90),
         table: [pid_t: ProcessSnapshot] = Rig.table((100, "teainate")),
         storeSnapshotter: (any ProcessSnapshotting)? = nil,
         foreign: [ForeignAssertion] = []) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teainate-lid-\(UUID().uuidString)")
        stateFile = dir.appendingPathComponent("holds.json")
        settings = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let snap = StubSnapshotter(table: table)
        service = TeainateService(
            store: HoldStore(fileURL: stateFile, snapshotter: storeSnapshotter ?? snap),
            spawner: spawner, assertionReader: StubAssertions(value: foreign), snapshotter: snap,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            lidClosed: LidClosedDependencies(
                flag: flag, grant: FakeGrant(granted: grant), battery: StubBattery(state: battery),
                settings: settings, watcherSpawner: watcher,
                watcherExecutable: URL(fileURLWithPath: "/usr/local/bin/teainate"), stateFile: stateFile)
        )
    }

    static func table(_ entries: (pid_t, String)...) -> [pid_t: ProcessSnapshot] {
        var t: [pid_t: ProcessSnapshot] = [:]
        for (pid, name) in entries { t[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: name) }
        return t
    }

    func lid(duration: TimeInterval? = 7200, watched: pid_t? = nil, acOnly: Bool = false) -> HoldOptions {
        HoldOptions(duration: duration, watchedPID: watched, acOnly: acOnly, lidClosed: true, source: .cli)
    }
}

@Test func refusedWithoutGrantAndTouchesNothing() {
    let rig = Rig(grant: false)
    #expect(throws: ServiceError.lidClosedNotEnabled) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
    #expect(rig.watcher.launches.isEmpty)
}

@Test func refusedAtOrBelowFloorOnBattery() {
    let rig = Rig(battery: BatteryState(source: .battery, percent: 14))
    #expect(throws: ServiceError.batteryBelowFloor(percent: 14, floor: 15)) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
}

@Test func allowedAboveFloorOnBatteryAndAtAnyLevelOnAC() throws {
    let above = Rig(battery: BatteryState(source: .battery, percent: 16))
    _ = try above.service.on(above.lid())
    let ac = Rig(battery: BatteryState(source: .ac, percent: 3))
    _ = try ac.service.on(ac.lid())
}

@Test func acOnlyRefusedWhileOnBattery() {
    let rig = Rig(battery: BatteryState(source: .battery, percent: 90))
    #expect(throws: ServiceError.notOnACPower) { try rig.service.on(rig.lid(acOnly: true)) }
}

@Test func refusedWhenFlagIsSetBySomethingElse() {
    let rig = Rig()
    rig.flag.value = true
    #expect(throws: ServiceError.sleepDisabledElsewhere) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 0)
}

@Test func brokenGrantIsReportedAsSuch() {
    let rig = Rig()
    rig.flag.failSet = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    do { _ = try rig.service.on(rig.lid()) } catch let ServiceError.lidClosedGrantBroken(message) {
        #expect(message.contains("password"))
    } catch { Issue.record("wrong error \(error)") }
    #expect(rig.watcher.launches.isEmpty)
}

@Test func successSetsFlagSpawnsWatcherRecordsHoldAndMarker() throws {
    let rig = Rig()
    try rig.settings.write(Settings(batteryFloor: 20))

    let hold = try rig.service.on(rig.lid(duration: nil, watched: 6707))

    #expect(rig.flag.setCount == 1)
    #expect(rig.watcher.launches.count == 1)
    #expect(rig.watcher.launches[0].0.path == "/usr/local/bin/teainate")
    #expect(rig.watcher.launches[0].1 == [
        "lid-watch", "--id", hold.id, "--floor", "20", "--state-file", rig.stateFile.path,
        "--caffeinate", "-i", "--watch-pid", "6707"])
    #expect(hold.lidClosed == true)
    #expect(hold.batteryFloor == 20)
    #expect(hold.caffeinatePID == 100)
    #expect(hold.flags == ["-i"])            // no -w: the watcher owns that slot

    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate")))).readState()
    #expect(state.lidFlagOwned == true)
    #expect(state.holds.map(\.id) == [hold.id])
}

@Test func failedWatcherSpawnClearsFlagAndRecordsNothing() throws {
    let rig = Rig()
    rig.watcher.shouldFail = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    #expect(rig.flag.setCount == 1)
    #expect(rig.flag.clearCount == 1)
    #expect(try rig.service.status().holds.isEmpty)
}

@Test func failedRecordTerminatesWatcherAndClearsFlag() throws {
    final class Flaky: ProcessSnapshotting, @unchecked Sendable {
        var calls = 0
        func snapshot() throws -> [pid_t: ProcessSnapshot] {
            calls += 1
            // First two calls: orphan check + ownership read in on(); third is the record.
            if calls == 3 { throw ServiceError.spawnFailed("store boom") }
            return Rig.table((100, "teainate"))
        }
    }
    let rig = Rig(storeSnapshotter: Flaky())
    #expect(throws: (any Error).self) { try rig.service.on(rig.lid()) }
    #expect(rig.spawner.terminated == [100])
    #expect(rig.flag.clearCount == 1)
}

@Test func clearFailureAfterSpawnFailureIsReportedAsStuck() {
    let rig = Rig()
    rig.watcher.shouldFail = true
    rig.flag.failClear = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }
    do { _ = try rig.service.on(rig.lid()) } catch ServiceError.sleepFlagStuck { } catch {
        Issue.record("expected sleepFlagStuck, got \(error)")
    }
}

@Test func secondLidHoldJoinsAndFlagClearsOnlyAfterTheLast() throws {
    let rig = Rig(table: Rig.table((100, "teainate"), (101, "teainate")))
    let first = try rig.service.on(rig.lid())
    let second = try rig.service.on(rig.lid())

    _ = try rig.service.off(id: first.id)
    #expect(rig.flag.clearCount == 0)
    #expect(try rig.service.status().lidClosed.flagSetBy == "teainate")

    _ = try rig.service.off(id: second.id)
    #expect(rig.flag.clearCount == 1)
    #expect(try rig.service.status().lidClosed.flagSet == false)
}

@Test func orphanedFlagIsClearedOnRead() throws {
    let rig = Rig(table: [:])            // no live processes at all
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()

    #expect(rig.flag.clearCount == 1)
    #expect(status.lidClosed.flagSet == false)
    #expect(status.lidClosed.warning == nil)
}

@Test func orphanedFlagThatCannotBeClearedWarns() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()
    #expect(status.lidClosed.warning?.contains("sudo pmset -a disablesleep 0") == true)
    #expect(status.lidClosed.flagSetBy == "teainate")
}

@Test func staleMarkerWithFlagAlreadyClearIsDroppedWithoutSudo() throws {
    // After a reboot the flag is gone but the marker survived; no clear call is needed.
    let rig = Rig(table: [:])
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSetBy == nil)
    #expect(status.lidClosed.warning == nil)
}

@Test func flagSetElsewhereIsReportedNotTouched() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    let status = try rig.service.status()
    #expect(rig.flag.clearCount == 0)
    #expect(status.lidClosed.flagSetBy == "other")
    #expect(status.lidClosed.warning?.contains("outside teainate") == true)
}

@Test func watcherChildIsNeitherUntrackedNorForeign() throws {
    var table = Rig.table((100, "teainate"))
    table[200] = ProcessSnapshot(pid: 200, parentPID: 100, command: "caffeinate", arguments: "caffeinate -i -w 100")
    table[300] = ProcessSnapshot(pid: 300, parentPID: 1, command: "caffeinate", arguments: "caffeinate -i")
    let rig = Rig(table: table, foreign: [
        ForeignAssertion(pid: 200, process: "caffeinate", type: "PreventUserIdleSystemSleep"),
        ForeignAssertion(pid: 300, process: "caffeinate", type: "PreventUserIdleSystemSleep"),
    ])
    _ = try rig.service.on(rig.lid())

    let status = try rig.service.status()
    #expect(status.untrackedCaffeinate.map(\.pid) == [300])
    #expect(status.foreignAssertions.map(\.pid) == [300])
    #expect(status.holds.first?.lidClosed == true)
    #expect(status.holds.first?.batteryFloor == 15)
}

@Test func statusReportsGrantAndFloor() throws {
    let rig = Rig()
    try rig.settings.write(Settings(batteryFloor: 30))
    let status = try rig.service.status()
    #expect(status.lidClosed.enabled == true)
    #expect(status.lidClosed.batteryFloor == 30)
}

@Test func lidClosedUnavailableWithoutDependencies() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("teainate-\(UUID().uuidString)/holds.json")
    let service = TeainateService(
        store: HoldStore(fileURL: url, snapshotter: StubSnapshotter(table: [:])),
        spawner: RecordingSpawner(), assertionReader: StubAssertions(), snapshotter: StubSnapshotter(table: [:]))
    #expect(throws: ServiceError.lidClosedUnavailable) {
        try service.on(HoldOptions(duration: 60, lidClosed: true, source: .cli))
    }
}
