import Testing
import Foundation
@testable import TeainateCore

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var value = false
    var setCount = 0
    var clearCount = 0
    /// Every call into `clear()`, whether or not it goes on to fail — lets a test prove
    /// a code path never even attempted the privileged clear, not just that it didn't
    /// succeed.
    var clearAttempts = 0
    var failSet = false
    var failClear = false
    var failIsSet = false
    func set() throws {
        if failSet { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        setCount += 1; value = true
    }
    func clear() throws {
        clearAttempts += 1
        if failClear { throw SleepFlagError.commandFailed(status: 1, message: "sudo: a password is required") }
        clearCount += 1; value = false
    }
    func isSet() throws -> Bool {
        if failIsSet { throw SleepFlagError.commandFailed(status: 1, message: "pmset -g failed") }
        return value
    }
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
    /// Fired at the start of every `spawnWatcher` call, before the `shouldFail` check —
    /// lets a test inject a store write exactly in the window this call represents, to
    /// simulate a concurrent process's `on` call landing its own hold in the gap between
    /// this call's own pre-flight read and this call's own failure.
    var onSpawn: (() -> Void)?
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        onSpawn?()
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

private struct StubStartTimes: ProcessStartTimeReading {
    var times: [pid_t: ProcessStartTime]
    func startTime(of pid: pid_t) -> ProcessStartTime? { times[pid] }
}

/// A mutable time source the Rig's `now` closure captures by reference, so a test can
/// advance the clock (e.g. past `lidFlagGracePeriod`) after the service is constructed.
private final class Clock: @unchecked Sendable {
    var time = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { time = time.addingTimeInterval(seconds) }
}

private struct Rig {
    let flag = FakeFlag()
    let watcher = RecordingWatcherSpawner()
    let spawner = RecordingSpawner()
    let clock = Clock()
    let stateFile: URL
    let settings: SettingsStore
    let service: TeainateService

    init(grant: Bool = true, battery: BatteryState? = BatteryState(source: .ac, percent: 90),
         table: [pid_t: ProcessSnapshot] = Rig.table((100, "teainate")),
         storeSnapshotter: (any ProcessSnapshotting)? = nil,
         foreign: [ForeignAssertion] = [],
         // Never the real ProcPIDInfoStartTimeReader: RecordingWatcherSpawner starts
         // its pids at 100, which does not correspond to any real process on the host
         // running this test, so a real reader would silently and non-deterministically
         // decide whether the test exercises the legacy name-only reconciliation path
         // or the stamped one. Defaulting to an explicit empty stub keeps the suite
         // hermetic and deterministic.
         startTimes: any ProcessStartTimeReading = StubStartTimes(times: [:])) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teainate-lid-\(UUID().uuidString)")
        stateFile = dir.appendingPathComponent("holds.json")
        settings = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let snap = StubSnapshotter(table: table)
        let clock = self.clock
        service = TeainateService(
            store: HoldStore(fileURL: stateFile, snapshotter: storeSnapshotter ?? snap, startTimes: startTimes, now: { clock.time }),
            spawner: spawner, assertionReader: StubAssertions(value: foreign), snapshotter: snap,
            now: { clock.time },
            lidClosed: LidClosedDependencies(
                flag: flag, grant: FakeGrant(granted: grant), battery: StubBattery(state: battery),
                settings: settings, watcherSpawner: watcher,
                watcherExecutable: URL(fileURLWithPath: "/usr/local/bin/teainate"), stateFile: stateFile),
            startTimes: startTimes
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

// The lid-closed hold's recorded pid is the watcher, not caffeinate (see CLAUDE.md's
// "ucomm is teainate, not caffeinate" trap) — this proves the stamped-start-time path
// round-trips through that watcher pid too, not just the ordinary caffeinate path
// covered by ServiceTests.onRecordsTheSpawnedProcessStartTime.
@Test func lidClosedHoldSurvivesReconciliationWithAStampedStartTime() throws {
    let stamp = ProcessStartTime(seconds: 2_000, microseconds: 5)
    let rig = Rig(startTimes: StubStartTimes(times: [100: stamp]))

    let hold = try rig.service.on(rig.lid())

    #expect(hold.processStartedAt == stamp)
    #expect(try rig.service.status().holds.map(\.id) == [hold.id])
}

@Test func recordingTheHoldClearsThePendingStamp() throws {
    // The stamp exists to shield an `on` still in flight from orphan cleanup; once the
    // hold is recorded there is nothing left in flight, so it must not linger and start
    // a fresh grace window the next time an orphan really does need cleaning up.
    let rig = Rig()

    _ = try rig.service.on(rig.lid())

    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate")))).readState()
    #expect(state.lidFlagPendingSince == nil)
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

@Test func failedSetLeavesMarkerTrueButNextReadSelfHealsWithoutSudo() throws {
    // A crash (or here, a failed sudo call) between persisting the marker and actually
    // setting the flag must not look like "someone else disabled sleep" on the next
    // read: the marker says the flag is teainate's to check on, so `status` clears it
    // for free once it sees the flag was never actually set — no clear() call needed.
    let rig = Rig()
    rig.flag.failSet = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }

    let afterFailure = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate")))).readState()
    #expect(afterFailure.lidFlagOwned == true)

    // The failed attempt's pending stamp would otherwise hold orphan cleanup off for
    // `lidFlagGracePeriod` — advance past it so this `status()` call actually exercises
    // cleanup rather than just the grace-period guard (covered separately below).
    rig.clock.advance(by: lidFlagGracePeriod + 1)
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSet == false)
    #expect(rig.flag.clearAttempts == 0)

    let afterStatus = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate")))).readState()
    #expect(afterStatus.lidFlagOwned == false)
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

@Test func secondFailureLeavesTheFirstLiveHoldAndFlagAlone() throws {
    // `undo`'s guard against a live lid-closed hold exists so a failed *second* attempt
    // never tears down the flag out from under a still-live first lid-closed hold. Here
    // the first hold is already live when the second call starts, so this covers the
    // guard reading a live hold that was there from the beginning.
    let rig = Rig(table: Rig.table((100, "teainate"), (101, "teainate")))
    let first = try rig.service.on(rig.lid())

    rig.watcher.shouldFail = true
    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }

    #expect(rig.flag.clearCount == 0)
    #expect(rig.flag.value == true)
    #expect(try rig.service.status().holds.map(\.id) == [first.id])
}

@Test func undoRereadsLiveHoldsInsteadOfTrustingItsOwnStaleCapture() throws {
    // The race this guards against: this call's own pre-flight read captures "no live
    // lid-closed hold" (nothing has been recorded yet, by anyone) — then, in the gap
    // before its watcher spawn fails, a concurrent process's `on` call finishes and
    // records its own live lid-closed hold. `undo` must read the store fresh rather
    // than trust a value captured before this call even set the flag, or it would clear
    // the flag out from under that concurrent hold. `onSpawn` stands in for the
    // concurrent process's write landing in exactly that window.
    let rig = Rig(table: Rig.table((100, "teainate"), (101, "teainate")))
    rig.watcher.shouldFail = true
    rig.watcher.onSpawn = { [stateFile = rig.stateFile] in
        try? HoldStore(
            fileURL: stateFile,
            snapshotter: StubSnapshotter(table: Rig.table((100, "teainate"), (101, "teainate")))
        ).mutateState { state in
            state.holds.append(Hold(
                id: "h_concurrent", kind: .forever, label: nil, source: .cli,
                caffeinatePID: 101, flags: ["-i"], startedAt: Date(timeIntervalSince1970: 1_000_000),
                expiresAt: nil, watchedPID: nil, display: false, acOnly: false,
                lidClosed: true, batteryFloor: 15))
        }
    }

    #expect(throws: ServiceError.self) { try rig.service.on(rig.lid()) }

    #expect(rig.flag.clearCount == 0)
    #expect(rig.flag.value == true)
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSetBy == "teainate")
    #expect(status.holds.map(\.id) == ["h_concurrent"])
}

@Test func orphanCleanupWaitsWhileAnOnIsInFlight() throws {
    // A fresh pending stamp looks exactly like the orphan signature (marker true, no
    // live hold, flag set) — that's the point: cleanup must not act on it within the
    // grace period, or it could clear the flag out from under an `on` still setting up.
    let rig = Rig(table: [:])
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { state in
            state.lidFlagOwned = true
            state.lidFlagPendingSince = rig.clock.time
        }

    let status = try rig.service.status()

    #expect(rig.flag.clearAttempts == 0)
    #expect(status.lidClosed.flagSetBy == "teainate")
    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:])).readState()
    #expect(state.lidFlagOwned == true)
}

@Test func orphanCleanupProceedsAfterTheGrace() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { state in
            state.lidFlagOwned = true
            state.lidFlagPendingSince = rig.clock.time.addingTimeInterval(-(lidFlagGracePeriod + 1))
        }

    let status = try rig.service.status()

    #expect(rig.flag.clearAttempts == 1)
    #expect(status.lidClosed.flagSet == false)
    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:])).readState()
    #expect(state.lidFlagOwned == false)
    #expect(state.lidFlagPendingSince == nil)
}

@Test func orphanedFlagIsClearedOnRead() throws {
    let rig = Rig(table: [:])            // no live processes at all
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()

    #expect(rig.flag.clearCount == 1)
    #expect(status.lidClosed.flagSet == false)
    #expect(status.lidClosed.warnings.isEmpty)
}

@Test func orphanedFlagThatCannotBeClearedWarns() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }

    let status = try rig.service.status()
    #expect(status.lidClosed.warnings.contains { $0.contains("sudo pmset -a disablesleep 0") })
    #expect(status.lidClosed.flagSetBy == "teainate")
}

@Test func staleMarkerWithFlagAlreadyClearIsDroppedWithoutSudo() throws {
    // After a reboot the flag is gone but the marker survived; no clear call is needed.
    // `failClear = true` would surface as a warning if `clear()` were ever reached —
    // it deliberately is not, so this also proves the code took the "already clear"
    // branch rather than the "clear succeeded" branch.
    let rig = Rig(table: [:])
    rig.flag.failClear = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.lidFlagOwned = true }
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSetBy == nil)
    #expect(status.lidClosed.warnings.isEmpty)
    #expect(rig.flag.clearAttempts == 0)
    let state = try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:])).readState()
    #expect(state.lidFlagOwned == false)
}

@Test func flagSetElsewhereIsReportedNotTouched() throws {
    let rig = Rig(table: [:])
    rig.flag.value = true
    let status = try rig.service.status()
    #expect(rig.flag.clearCount == 0)
    #expect(status.lidClosed.flagSetBy == "other")
    #expect(status.lidClosed.warnings.contains { $0.contains("outside teainate") })
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
    // 200 is our watcher's child; 300 is already described (with its flags) as
    // untracked, so neither is repeated as a foreign assertion.
    #expect(status.foreignAssertions.isEmpty)
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

@Test func ordinaryOnAlsoClearsAnOrphanedFlag() throws {
    // "Every read reconciles" (CLAUDE.md) applies to the flag marker too — an ordinary,
    // non-lid-closed `on` must not leave a stale flag/marker sitting there just because
    // the caller didn't ask for a lid-closed hold this time.
    let rig = Rig()
    rig.flag.value = true
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: Rig.table((100, "teainate"))))
        .mutateState { $0.lidFlagOwned = true }

    _ = try rig.service.on(HoldOptions(source: .cli))

    #expect(rig.flag.clearCount == 1)
}

@Test func unreadableFlagIsReportedAsUnknownNotFalse() throws {
    let rig = Rig(table: [:])
    rig.flag.failIsSet = true
    let status = try rig.service.status()
    #expect(status.lidClosed.flagSet == nil)
    #expect(status.lidClosed.flagSetBy == nil)
    #expect(status.lidClosed.warnings.contains { $0.contains("Could not read the sleep-disabled flag") })
}

@Test func settingsWarningSurvivesAFlagWarning() throws {
    let rig = Rig(table: [:])
    try FileManager.default.createDirectory(at: rig.settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ nope".write(to: rig.settings.fileURL, atomically: true, encoding: .utf8)
    rig.flag.value = true                    // set by someone else
    let warnings = try rig.service.status().lidClosed.warnings
    #expect(warnings.contains { $0.contains("settings.json") })
    #expect(warnings.contains { $0.contains("outside teainate") })
}

@Test func corruptStateFileWarnsForTenMinutesThenStops() throws {
    let rig = Rig(table: [:])
    try FileManager.default.createDirectory(at: rig.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ not json".write(to: rig.stateFile, atomically: true, encoding: .utf8)

    #expect(try rig.service.status().lidClosed.warnings.contains { $0.contains("state file was corrupt") })
    rig.clock.advance(by: 601)
    #expect(try rig.service.status().lidClosed.warnings.isEmpty)
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

// A backwards clock step must not resurrect the corrupt-state warning: a reset stamp
// in the future is outside the window, not inside it.
@Test func resetStampInTheFutureDoesNotWarn() throws {
    let rig = Rig(table: [:])
    let future = rig.clock.time.addingTimeInterval(100)
    try HoldStore(fileURL: rig.stateFile, snapshotter: StubSnapshotter(table: [:]))
        .mutateState { $0.stateResetAt = future }
    #expect(try rig.service.status().lidClosed.warnings.isEmpty)
}
