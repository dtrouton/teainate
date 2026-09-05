import Testing
import Foundation
@testable import TeainateCore

private func realService() -> (TeainateService, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-integration-\(UUID().uuidString)")
        .appendingPathComponent("holds.json")
    let snapshotter = PSProcessSnapshotter()
    let service = TeainateService(
        store: HoldStore(fileURL: url, snapshotter: snapshotter),
        spawner: SystemCaffeinateSpawner(),
        assertionReader: PMSetAssertionReader(),
        snapshotter: snapshotter
    )
    return (service, url)
}

// Every hold below carries a short `duration`, which becomes caffeinate's own `-t`
// timeout. That is a backstop, not the primary cleanup path: each test still releases
// (or in the kill test, signals) the process itself. If a test crashed before reaching
// its `defer`, the spawned process would still self-terminate within seconds rather than
// holding the Mac awake indefinitely.

@Test func realHoldAppearsInPmsetAndReleasesCleanly() throws {
    let (service, _) = realService()
    let hold = try service.on(HoldOptions(duration: 20, label: "integration", source: .cli))

    defer { _ = try? service.off(id: nil) }

    // The spawned process is real and is caffeinate.
    let table = try PSProcessSnapshotter().snapshot()
    #expect(table[hold.caffeinatePID]?.command == "caffeinate")

    // The system agrees something is holding it awake.
    let assertions = try PMSetAssertionReader().assertions()
    #expect(assertions.contains { $0.pid == hold.caffeinatePID })

    #expect(try service.status().awake)

    let released = try service.off(id: hold.id)
    #expect(released.map(\.id) == [hold.id])

    // SIGTERM is asynchronous; give the process a moment to actually exit.
    var attempts = 0
    while attempts < 50, try PSProcessSnapshotter().snapshot()[hold.caffeinatePID] != nil {
        usleep(100_000)
        attempts += 1
    }
    #expect(try PSProcessSnapshotter().snapshot()[hold.caffeinatePID] == nil)
    #expect(try service.status().awake == false)
}

@Test func spawnedCaffeinateSurvivesAndCarriesRequestedFlags() throws {
    let (service, _) = realService()
    let hold = try service.on(HoldOptions(duration: 20, display: true, source: .cli))
    defer { _ = try? service.off(id: nil) }

    #expect(hold.flags == ["-i", "-d", "-t", "20"])

    let assertions = try PMSetAssertionReader().assertions()
    let ours = assertions.filter { $0.pid == hold.caffeinatePID }
    #expect(!ours.isEmpty)
}

@Test func killedProcessIsReconciledAway() throws {
    let (service, _) = realService()
    let hold = try service.on(HoldOptions(duration: 20, source: .cli))

    // Simulate a crash: kill the caffeinate process behind teainate's back.
    kill(hold.caffeinatePID, SIGKILL)

    var attempts = 0
    while attempts < 50, try PSProcessSnapshotter().snapshot()[hold.caffeinatePID] != nil {
        usleep(100_000)
        attempts += 1
    }

    // The stale record must not survive the next read.
    #expect(try service.status().holds.isEmpty)
}

// The recycling gap, closed: a record that carries process A's start time must not
// adopt process B just because B reuses A's pid and name. We cannot force the kernel to
// reuse a pid, so the test transplants A's stamp onto B's pid — the exact state a
// recycled record would be in.
@Test func realStartTimeDistinguishesTwoCaffeinateProcesses() throws {
    let spawner = SystemCaffeinateSpawner()
    let reader = ProcPIDInfoStartTimeReader()
    let a = try spawner.spawn(flags: ["-i", "-t", "20"])
    defer { spawner.terminate(pid: a) }
    let b = try spawner.spawn(flags: ["-i", "-t", "20"])
    defer { spawner.terminate(pid: b) }

    let startA = try #require(reader.startTime(of: a))
    let table = try PSProcessSnapshotter().snapshot()

    var genuine = Hold(id: "a", kind: .timer, label: nil, source: .cli, caffeinatePID: a, flags: ["-i"],
                       startedAt: Date(), expiresAt: nil, watchedPID: nil, display: false, acOnly: false)
    genuine.processStartedAt = startA
    #expect(reconcile([genuine], against: table, startTime: reader.startTime(of:)).map(\.id) == ["a"])

    var recycled = genuine
    recycled.id = "recycled"
    recycled.caffeinatePID = b                    // b's pid, a's start time
    #expect(reconcile([recycled], against: table, startTime: reader.startTime(of:)).isEmpty)
}

@Test func realServiceRecordsStartTimeAndSurvivesReads() throws {
    let (service, _) = realService()
    let hold = try service.on(HoldOptions(duration: 20, source: .cli))
    defer { _ = try? service.off(id: nil) }
    #expect(hold.processStartedAt != nil)
    #expect(hold.processStartedAt == ProcPIDInfoStartTimeReader().startTime(of: hold.caffeinatePID))
    #expect(try service.status().holds.map(\.id) == [hold.id])
}
