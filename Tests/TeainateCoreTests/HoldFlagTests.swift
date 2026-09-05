import Testing
import Foundation
@testable import TeainateCore

private func opts(
    duration: TimeInterval? = nil,
    watchedPID: pid_t? = nil,
    acOnly: Bool = false,
    display: Bool = false
) -> HoldOptions {
    HoldOptions(
        duration: duration, watchedPID: watchedPID,
        acOnly: acOnly, display: display,
        label: nil, source: .cli
    )
}

@Test func defaultIsIdleSleepPreventionOnAnyPower() {
    #expect(caffeinateFlags(for: opts()) == ["-i"])
}

@Test func acOnlyUsesSystemSleepFlag() {
    #expect(caffeinateFlags(for: opts(acOnly: true)) == ["-s"])
}

@Test func displayAddsDisplayFlag() {
    #expect(caffeinateFlags(for: opts(display: true)) == ["-i", "-d"])
}

@Test func timedHoldAddsTimeout() {
    #expect(caffeinateFlags(for: opts(duration: 7200)) == ["-i", "-t", "7200"])
}

@Test func processHoldAddsWait() {
    #expect(caffeinateFlags(for: opts(watchedPID: 6707)) == ["-i", "-w", "6707"])
}

@Test func axesComposeInStableOrder() {
    let flags = caffeinateFlags(for: opts(duration: 7200, acOnly: true, display: true))
    #expect(flags == ["-s", "-d", "-t", "7200"])
}

@Test func kindDerivesFromOptions() {
    #expect(opts().kind == .forever)
    #expect(opts(duration: 60).kind == .timer)
    #expect(opts(watchedPID: 1).kind == .process)
}

@Test func processKindWinsOverTimer() {
    // -w and -t together: the watched process is the meaningful lifetime.
    #expect(opts(duration: 60, watchedPID: 1).kind == .process)
}

@Test func holdRoundTripsThroughSnakeCaseJSON() throws {
    let hold = Hold(
        id: "h_3f2a", kind: .timer, label: "2h timer", source: .menu,
        caffeinatePID: 6707, flags: ["-i", "-t", "7200"],
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_700_007_200),
        watchedPID: nil, display: false, acOnly: false
    )
    let data = try Hold.encoder.encode(hold)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"caffeinate_pid\""))
    #expect(json.contains("\"started_at\""))
    #expect(try Hold.decoder.decode(Hold.self, from: data) == hold)
}

@Test func idHasReadablePrefix() {
    #expect(makeHoldID(random: { 0x3f2a }) == "h_00003f2a")
}

// A lid-closed hold's caffeinate is spawned by the watcher, which needs the single
// `-w` slot for its own pid. The user's watched process is polled by the watcher instead.
@Test func lidClosedFlagsOmitTheWatchedPID() {
    var options = opts(watchedPID: 6707)
    options.lidClosed = true
    #expect(caffeinateFlags(for: options) == ["-i"])
}

@Test func lidClosedKeepsTimerAndDisplayFlags() {
    var options = opts(duration: 600, display: true)
    options.lidClosed = true
    #expect(caffeinateFlags(for: options) == ["-i", "-d", "-t", "600"])
}

// Int(TimeInterval.greatestFiniteMagnitude) traps. The clamp is the backstop for any
// caller that bypasses parseDuration.
@Test func absurdDurationIsClampedNotTrapped() {
    let flags = caffeinateFlags(for: opts(duration: .greatestFiniteMagnitude))
    #expect(flags == ["-i", "-t", String(Int(maxDurationSeconds))])
}
