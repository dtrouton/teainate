import Testing
import Foundation
@testable import TeainateCore

private let now = Date(timeIntervalSince1970: 1_000_000)

private func hold(
    kind: HoldKind = .timer, expiresAt: Date? = now.addingTimeInterval(2520),
    watched: pid_t? = nil, label: String? = "build", source: HoldSource = .cli,
    display: Bool = false, acOnly: Bool = false, lidClosed: Bool = false,
    replaces: String? = nil
) -> Hold {
    Hold(
        id: "h_orig", kind: kind, label: label, source: source, caffeinatePID: 100,
        flags: ["-i"], startedAt: now.addingTimeInterval(-60), expiresAt: expiresAt,
        watchedPID: watched, display: display, acOnly: acOnly, lidClosed: lidClosed,
        batteryFloor: lidClosed ? 15 : nil, replaces: replaces
    )
}

@Test func flipsOnlyTheRequestedModifier() throws {
    let base = hold(display: false, acOnly: true, lidClosed: false)
    let display = try #require(replacementOptions(for: base, changing: .display, to: true, now: now))
    #expect(display.display == true && display.acOnly == true && display.lidClosed == false)

    let ac = try #require(replacementOptions(for: base, changing: .acOnly, to: false, now: now))
    #expect(ac.display == false && ac.acOnly == false && ac.lidClosed == false)

    let lid = try #require(replacementOptions(for: base, changing: .lidClosed, to: true, now: now))
    #expect(lid.display == false && lid.acOnly == true && lid.lidClosed == true)
}

@Test func preservesKindLabelSourceAndWatchedPID() throws {
    let options = try #require(replacementOptions(
        for: hold(kind: .process, expiresAt: nil, watched: 6707, label: "migration", source: .claude),
        changing: .display, to: true, now: now))
    #expect(options.kind == .process)
    #expect(options.watchedPID == 6707)
    #expect(options.label == "migration")
    #expect(options.source == .claude)
    #expect(options.duration == nil)
}

@Test func timerCarriesRemainingSecondsNotOriginalLength() throws {
    let options = try #require(replacementOptions(
        for: hold(expiresAt: now.addingTimeInterval(2520)), changing: .display, to: true, now: now))
    #expect(options.duration == 2520)
    #expect(options.kind == .timer)
}

@Test func foreverHoldStaysForever() throws {
    let options = try #require(replacementOptions(
        for: hold(kind: .forever, expiresAt: nil), changing: .acOnly, to: true, now: now))
    #expect(options.kind == .forever)
    #expect(options.duration == nil)
}

@Test func underASecondLeftYieldsNothing() {
    #expect(replacementOptions(for: hold(expiresAt: now.addingTimeInterval(0.5)), changing: .display, to: true, now: now) == nil)
    #expect(replacementOptions(for: hold(expiresAt: now.addingTimeInterval(-10)), changing: .display, to: true, now: now) == nil)
}

@Test func lineagePointsAtTheFirstHoldInTheChain() throws {
    let first = try #require(replacementOptions(for: hold(), changing: .display, to: true, now: now))
    #expect(first.replaces == "h_orig")

    let later = try #require(replacementOptions(for: hold(replaces: "h_root"), changing: .display, to: true, now: now))
    #expect(later.replaces == "h_root")
}
