import Testing
import Foundation
@testable import TeainateCore

private final class BundleMarker {}

/// The CLI product built alongside the test bundle (`.build/<config>/teainate`).
private func cliBinary() throws -> URL {
    let url = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("teainate")
    try #require(FileManager.default.isExecutableFile(atPath: url.path),
                 "teainate CLI not built at \(url.path); run `swift build` first")
    return url
}

private func waitUntilGone(_ pid: pid_t) throws {
    var attempts = 0
    while attempts < 100, try PSProcessSnapshotter().snapshot()[pid] != nil {
        usleep(100_000); attempts += 1
    }
}

private func tempState() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-lidwatch-\(UUID().uuidString)/holds.json")
}

/// Forwards to the real spawner with `--no-flag` appended: a real watcher binary that
/// never touches the kernel sleep flag. The service itself never passes this hook.
private struct NoFlagWatcherSpawner: WatcherSpawning {
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        try SystemWatcherSpawner().spawnWatcher(executable: executable, arguments: arguments + ["--no-flag"])
    }
}

private final class FakeFlag: SleepFlagControlling, @unchecked Sendable {
    var value = false
    var clearCount = 0
    func set() throws { value = true }
    func clear() throws { clearCount += 1; value = false }
    func isSet() throws -> Bool { value }
}

private struct AlwaysGranted: PrivilegeGranting {
    func isGranted() -> Bool { true }
}

private struct OnACPower: BatteryReading {
    func read() throws -> BatteryState? { BatteryState(source: .ac, percent: 90) }
}

/// Real service, real caffeinate, real watcher binary, real ps; faked flag, grant, and
/// battery. The only shape of test that proves a lid transition composes correctly.
private func realLidService() throws -> (service: TeainateService, flag: FakeFlag, state: URL) {
    let state = tempState()
    let snapshotter = PSProcessSnapshotter()
    let flag = FakeFlag()
    let service = TeainateService(
        store: HoldStore(fileURL: state, snapshotter: snapshotter),
        spawner: SystemCaffeinateSpawner(),
        assertionReader: PMSetAssertionReader(),
        snapshotter: snapshotter,
        lidClosed: LidClosedDependencies(
            flag: flag, grant: AlwaysGranted(), battery: OnACPower(),
            settings: SettingsStore(fileURL: state.deletingLastPathComponent().appendingPathComponent("settings.json")),
            watcherSpawner: NoFlagWatcherSpawner(),
            watcherExecutable: try cliBinary(), stateFile: state)
    )
    return (service, flag, state)
}

private func storeState(_ state: URL) throws -> StoreState {
    try HoldStore(fileURL: state, snapshotter: PSProcessSnapshotter()).readState()
}

// Real watcher, real ps, faked flag (--no-flag). This is the one shape of test that
// catches a `ucomm` mismatch on the watcher's name — see CLAUDE.md.
@Test func realWatcherSurvivesReconciliationAndOwnsItsChild() throws {
    let state = tempState()
    let config = LidWatchConfig(holdID: "h_it", floor: 15, watchedPID: nil, acOnly: false,
                                caffeinateFlags: ["-i", "-t", "20"], label: nil)
    let args = lidWatchArguments(config, stateFile: state) + ["--no-flag"]
    let pid = try SystemWatcherSpawner().spawnWatcher(executable: try cliBinary(), arguments: args)
    defer { kill(pid, SIGTERM) }

    // Give it a moment to spawn its caffeinate child.
    var child: ProcessSnapshot?
    for _ in 0..<50 {
        let table = try PSProcessSnapshotter().snapshot()
        child = table.values.first { $0.parentPID == pid && $0.command == "caffeinate" }
        if child != nil { break }
        usleep(100_000)
    }
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[pid]?.command == watcherProcessName)
    #expect(child?.arguments.hasSuffix("-w \(pid)") == true)

    let record = Hold(id: "h_it", kind: .timer, label: nil, source: .cli, caffeinatePID: pid,
                      flags: ["-i", "-t", "20"], startedAt: Date(), expiresAt: nil, watchedPID: nil,
                      display: false, acOnly: false, lidClosed: true, batteryFloor: 15)
    #expect(reconcile([record], against: table, startTime: ProcPIDInfoStartTimeReader().startTime(of:)).map(\.id) == ["h_it"])
    #expect(ownedPIDs(of: [record], in: table).contains(child!.pid))

    kill(pid, SIGTERM)
    try waitUntilGone(pid)
    try waitUntilGone(child!.pid)
    #expect(try PSProcessSnapshotter().snapshot()[child!.pid] == nil)

    let log = try String(contentsOf: lidWatchLogURL(besideStateFile: state), encoding: .utf8)
    #expect(log.contains("h_it ended: released"))
}

// The no-orphan design rests on `-t` and `-w` combining. Verify both directions.
@Test func caffeinateTimerFiresWhileWatchedProcessLives() throws {
    let pid = try SystemCaffeinateSpawner().spawn(flags: ["-i", "-t", "2", "-w", String(getpid())])
    defer { kill(pid, SIGTERM) }
    sleep(3)
    try waitUntilGone(pid)
    #expect(try PSProcessSnapshotter().snapshot()[pid] == nil)
}

@Test func caffeinateReleasesWhenWatchedProcessExitsBeforeTimer() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { sleeper.terminate() }

    let pid = try SystemCaffeinateSpawner().spawn(
        flags: ["-i", "-t", "20", "-w", String(sleeper.processIdentifier)])
    defer { kill(pid, SIGTERM) }

    sleeper.terminate()
    try waitUntilGone(pid)
    #expect(try PSProcessSnapshotter().snapshot()[pid] == nil)
}

// off→on through the real service: a real watcher replaces a real caffeinate.
@Test func realModifyToLidClosedSpawnsAWatcherAndReleasesTheCaffeinate() throws {
    let (service, flag, state) = try realLidService()
    let plain = try service.on(HoldOptions(duration: 20, source: .menu))
    defer { _ = try? service.off(id: nil) }

    let lid = try service.modify(id: plain.id, changing: .lidClosed, to: true)

    #expect(lid.lidClosed)
    #expect(lid.replaces == plain.id)
    #expect(flag.value)
    try waitUntilGone(plain.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[plain.caffeinatePID] == nil)
    #expect(table[lid.caffeinatePID]?.command == watcherProcessName)
    #expect(try service.status().holds.map(\.id) == [lid.id])
    #expect(try storeState(state).lidFlagOwned)
}

// on→off: the watcher ran with --no-flag, so it cleared nothing on exit. The service's
// own orphan cleanup, run at the end of `off`, is what clears the fake flag.
@Test func realModifyFromLidClosedReleasesTheWatcherAndClearsTheFlag() throws {
    let (service, flag, state) = try realLidService()
    let lid = try service.on(HoldOptions(duration: 20, lidClosed: true, source: .menu))
    defer { _ = try? service.off(id: nil) }
    #expect(flag.value)

    let plain = try service.modify(id: lid.id, changing: .lidClosed, to: false)

    #expect(!plain.lidClosed)
    try waitUntilGone(lid.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[lid.caffeinatePID] == nil)
    #expect(table[plain.caffeinatePID]?.command == "caffeinate")
    #expect(flag.value == false)
    #expect(flag.clearCount == 1)
    #expect(try storeState(state).lidFlagOwned == false)
    #expect(try service.status().holds.map(\.id) == [plain.id])
}

// on→on: two real watchers overlap, then only the new one remains; the flag is never cleared.
@Test func realModifyOnALidHoldSwapsWatchersWithoutClearingTheFlag() throws {
    let (service, flag, state) = try realLidService()
    let first = try service.on(HoldOptions(duration: 20, lidClosed: true, source: .menu))
    defer { _ = try? service.off(id: nil) }

    let second = try service.modify(id: first.id, changing: .display, to: true)

    #expect(second.lidClosed && second.display)
    try waitUntilGone(first.caffeinatePID)
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[first.caffeinatePID] == nil)
    #expect(table[second.caffeinatePID]?.command == watcherProcessName)
    #expect(flag.value)
    #expect(flag.clearCount == 0)
    #expect(try storeState(state).lidFlagOwned)
    #expect(try service.status().holds.map(\.id) == [second.id])
}
