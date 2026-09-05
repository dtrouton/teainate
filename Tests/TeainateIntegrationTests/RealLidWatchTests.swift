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
