import Testing
import Foundation
@testable import TeainateCore

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var setCount = 0
    var clearCount = 0
    var failClear = false
    var value = true
    func set() throws { setCount += 1; value = true }
    func clear() throws {
        if failClear { throw SleepFlagError.commandFailed(status: 1, message: "no grant") }
        clearCount += 1; value = false
    }
    func isSet() throws -> Bool { value }
}

private final class ScriptedLiveness: ProcessLiveness, @unchecked Sendable {
    /// Per pid, the answers to give in order; the last one repeats.
    var script: [pid_t: [Bool]]
    init(_ script: [pid_t: [Bool]]) { self.script = script }
    func isAlive(_ pid: pid_t) -> Bool {
        guard var answers = script[pid], !answers.isEmpty else { return false }
        let answer = answers.removeFirst()
        if !answers.isEmpty { script[pid] = answers }
        return answer
    }
}

private final class RecordingSpawner: CaffeinateSpawning, @unchecked Sendable {
    var spawned: [[String]] = []
    var terminated: [pid_t] = []
    func spawn(flags: [String]) throws -> pid_t { spawned.append(flags); return 900 }
    func terminate(pid: pid_t) { terminated.append(pid) }
}

private struct StubBattery: BatteryReading {
    var state: BatteryState?
    func read() throws -> BatteryState? { state }
}

private struct FakeSnapshotter: ProcessSnapshotting {
    let table: [pid_t: ProcessSnapshot]
    func snapshot() throws -> [pid_t: ProcessSnapshot] { table }
}

private let watcherPID: pid_t = 4242

private func lidHold(_ id: String, pid: pid_t) -> Hold {
    Hold(id: id, kind: .timer, label: "build", source: .cli, caffeinatePID: pid, flags: ["-i", "-t", "60"],
         startedAt: Date(timeIntervalSince1970: 0), expiresAt: nil, watchedPID: nil,
         display: false, acOnly: false, lidClosed: true, batteryFloor: 15)
}

private struct Harness {
    let store: HoldStore
    let flag = FakeFlag()
    let spawner = RecordingSpawner()
    let logged = LogSink()
    final class LogSink: @unchecked Sendable { var lines: [String] = [] }

    init(table: [pid_t: ProcessSnapshot]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teainate-runner-\(UUID().uuidString)/holds.json")
        store = HoldStore(fileURL: url, snapshotter: FakeSnapshotter(table: table))
    }

    func runner(liveness: ScriptedLiveness, battery: BatteryState? = BatteryState(source: .ac, percent: 90),
                manageFlag: Bool = true) -> LidWatchRunner {
        let sink = logged
        return LidWatchRunner(dependencies: .init(
            store: store, spawner: spawner, battery: StubBattery(state: battery),
            flag: manageFlag ? flag : nil, liveness: liveness,
            log: { sink.lines.append($0) }, sleep: { _ in }, now: { Date(timeIntervalSince1970: 5_000) },
            checkInterval: 1
        ))
    }

    static func table(_ entries: (pid_t, String)...) -> [pid_t: ProcessSnapshot] {
        var t: [pid_t: ProcessSnapshot] = [:]
        for (pid, name) in entries { t[pid] = ProcessSnapshot(pid: pid, parentPID: 1, command: name) }
        return t
    }

    var config: LidWatchConfig {
        LidWatchConfig(holdID: "h_1", floor: 15, watchedPID: nil, acOnly: false,
                       caffeinateFlags: ["-i", "-t", "60"], label: "build")
    }
}

@Test func setsFlagAndSpawnsChildTiedToOwnPID() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.setCount == 1)
    #expect(h.spawner.spawned == [["-i", "-t", "60", "-w", "4242"]])
}

@Test func childExitEndsWithTimerExpiredAndClearsFlag() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }

    let reason = h.runner(liveness: ScriptedLiveness([900: [true, false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())

    #expect(reason == .timerExpired)
    #expect(h.spawner.terminated == [900])
    #expect(h.flag.clearCount == 1)
    let state = try h.store.readState()
    #expect(state.holds.isEmpty)
    #expect(state.lidFlagOwned == false)
    #expect(state.lastEnded == nil)          // not a reason worth explaining
    #expect(h.logged.lines.contains { $0.contains("h_1 ended: timer expired") })
}

@Test func floorEndsAndRecordsLastEnded() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }

    let reason = h.runner(liveness: ScriptedLiveness([900: [true]]),
                          battery: BatteryState(source: .battery, percent: 14))
        .run(h.config, ownPID: watcherPID, stop: StopFlag())

    #expect(reason == .batteryAtFloor(percent: 14, floor: 15))
    let ended = try h.store.readState().lastEnded
    #expect(ended?.id == "h_1")
    #expect(ended?.label == "build")
    #expect(ended?.reason == "battery 14% at floor 15%")
    #expect(ended?.at == Date(timeIntervalSince1970: 5_000))
}

@Test func stopFlagEndsWithReleasedAndRecordsNothing() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    let stop = StopFlag()
    stop.set()
    let reason = h.runner(liveness: ScriptedLiveness([900: [true]])).run(h.config, ownPID: watcherPID, stop: stop)
    #expect(reason == .released)
    #expect(h.spawner.terminated == [900])
    #expect(try h.store.readState().lastEnded == nil)
}

@Test func lastWatcherOutClearsTheFlagButNotBefore() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate"), (4343, "teainate")))
    try h.store.mutateState {
        $0.holds.append(lidHold("h_1", pid: watcherPID))
        $0.holds.append(lidHold("h_2", pid: 4343))
        $0.lidFlagOwned = true
    }
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.clearCount == 0)
    #expect(try h.store.readState().lidFlagOwned == true)
}

@Test func failedClearLeavesMarkerForOrphanCleanup() throws {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    h.flag.failClear = true
    try h.store.mutateState { $0.holds.append(lidHold("h_1", pid: watcherPID)); $0.lidFlagOwned = true }
    _ = h.runner(liveness: ScriptedLiveness([900: [false]])).run(h.config, ownPID: watcherPID, stop: StopFlag())
    let state = try h.store.readState()
    #expect(state.holds.isEmpty)
    #expect(state.lidFlagOwned == true)
    #expect(h.logged.lines.contains { $0.contains("could not clear") })
}

@Test func noFlagModeNeverTouchesTheFlag() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    _ = h.runner(liveness: ScriptedLiveness([900: [false]]), manageFlag: false)
        .run(h.config, ownPID: watcherPID, stop: StopFlag())
    #expect(h.flag.setCount == 0)
    #expect(h.flag.clearCount == 0)
}

@Test func watchedProcessExitEnds() {
    let h = Harness(table: Harness.table((watcherPID, "teainate")))
    var config = h.config
    config.watchedPID = 777
    let reason = h.runner(liveness: ScriptedLiveness([900: [true], 777: [false]]))
        .run(config, ownPID: watcherPID, stop: StopFlag())
    #expect(reason == .watchedProcessExited)
}
