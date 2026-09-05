import Testing
import Foundation
@testable import TeainateCore

private func status(
    awake: Bool = true,
    holds: [HoldStatus] = [],
    foreign: [ForeignAssertion] = [],
    untracked: [UntrackedCaffeinate] = [],
    lid: LidClosedStatus = .unavailable,
    pmsetAvailable: Bool = true
) -> Status {
    Status(
        awake: awake, holds: holds, foreignAssertions: foreign, untrackedCaffeinate: untracked,
        lidClosed: lid, pmsetAvailable: pmsetAvailable
    )
}

private func holdStatus(
    id: String = "h_1", kind: HoldKind = .forever, label: String? = nil,
    remaining: Int? = nil, display: Bool = false, acOnly: Bool = false,
    lidClosed: Bool = false, floor: Int? = nil
) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: label, source: .cli,
        expiresAt: nil, remainingSeconds: remaining, display: display, acOnly: acOnly,
        lidClosed: lidClosed, batteryFloor: floor
    )
}

@Test func rendersAsleepState() {
    #expect(renderStatus(status(awake: false)).contains("Not holding the Mac awake"))
}

@Test func rendersIndefiniteHold() {
    let text = renderStatus(status(holds: [holdStatus()]))
    #expect(text.contains("indefinitely"))
    #expect(text.contains("h_1"))
}

@Test func rendersRemainingTimeInMinutes() {
    let text = renderStatus(status(holds: [holdStatus(kind: .timer, remaining: 2520)]))
    #expect(text.contains("42 min left"))
}

// 119 is deliberately not a multiple of 60: integer division would floor it to
// "1 min left", which is off by nearly a full minute. It must round to 2.
@Test func rendersRemainingTimeRoundedRatherThanFloored() {
    let text = renderStatus(status(holds: [holdStatus(kind: .timer, remaining: 119)]))
    #expect(text.contains("2 min left"))
    #expect(!text.contains("1 min left"))
}

// Below one minute, "0 min left" reads as "your hold is spent" when up to 59
// seconds actually remain.
@Test func rendersSubMinuteRemainingAsLessThanAMinute() {
    let text = renderStatus(status(holds: [holdStatus(kind: .timer, remaining: 30)]))
    #expect(text.contains("less than a minute left"))
    #expect(!text.contains("0 min left"))
}

@Test func rendersModifierFlags() {
    let text = renderStatus(status(holds: [holdStatus(display: true, acOnly: true)]))
    #expect(text.contains("display on"))
    #expect(text.contains("while plugged in"))
}

@Test func rendersForeignAssertionsSection() {
    let text = renderStatus(status(
        foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]
    ))
    #expect(text.contains("Also keeping this Mac awake"))
    #expect(text.contains("Claude"))
}

@Test func omitsForeignSectionWhenEmpty() {
    #expect(!renderStatus(status()).contains("Also keeping this Mac awake"))
}

@Test func rendersUnavailableAssertionsInsteadOfNothing() {
    let text = renderStatus(status(awake: false, pmsetAvailable: false))
    #expect(text.contains("Other sleep assertions: unavailable (pmset failed)"))
    #expect(!text.contains("Also keeping this Mac awake"))
}

@Test func rendersUntrackedCaffeinateWithFlags() {
    let text = renderStatus(Status(
        awake: false, holds: [], foreignAssertions: [],
        untrackedCaffeinate: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i -t 300")]
    ))
    #expect(text.contains("not managed by teainate"))
    #expect(text.contains("caffeinate -i -t 300"))
    #expect(text.contains("555"))
    // Must warn about the consequence, not invite the action: `off --untracked` can
    // terminate another Claude Code session's real hold, so the hint must not read
    // as a suggestion to run it.
    #expect(text.contains("would terminate them"))
}

@Test func omitsUntrackedSectionWhenEmpty() {
    #expect(!renderStatus(status()).contains("not managed by teainate"))
}

@Test func labelledTimerShowsBothLabelAndRemainingTime() {
    let text = describe(holdStatus(kind: .timer, label: "build", remaining: 2520))
    #expect(text.contains("build"))
    #expect(text.contains("42 min left"))
}

@Test func labelledForeverHoldShowsLabelNotIndefinitely() {
    let text = describe(holdStatus(kind: .forever, label: "focus time"))
    #expect(text.contains("focus time"))
    #expect(!text.contains("indefinitely"))
}

@Test func labelledSessionHoldShowsBothLabelAndLifetime() {
    let text = describe(holdStatus(kind: .process, label: "pairing session"))
    #expect(text.contains("pairing session"))
    #expect(text.contains("until session exits"))
}

@Test func describesLidClosedModifiers() {
    let text = describe(holdStatus(kind: .timer, label: "build", remaining: 2520, lidClosed: true, floor: 15))
    #expect(text.contains("build — 42 min left"))
    #expect(text.contains("lid ok"))
    #expect(text.contains("off at 15%"))
}

@Test func rendersLidClosedWarning() {
    let lid = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15,
                              lastEnded: nil, warning: "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0")
    let text = renderStatus(status(awake: false, lid: lid))
    #expect(text.contains("⚠ The sleep-disabled flag is set"))
}

@Test func rendersLastEndedReason() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warning: nil)
    let text = renderStatus(status(awake: false, lid: lid))
    #expect(text.contains("Last lid-closed hold (build) ended: battery 14% at floor 15%"))
}

@Test func rendersEnablementLine() {
    let off = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)
    #expect(renderStatus(status(awake: false, lid: off)).contains("Lid-closed holds: not enabled"))
    let on = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 30, lastEnded: nil, warning: nil)
    #expect(renderStatus(status(awake: false, lid: on)).contains("Lid-closed holds: enabled (battery floor 30%)"))
}

@Test func statusJSONCarriesLidClosedKeys() throws {
    let lid = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "other", batteryFloor: 15, lastEnded: nil, warning: nil)
    let data = try Status.encoder.encode(status(holds: [holdStatus(lidClosed: true, floor: 15)], lid: lid))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"lid_closed\""))
    #expect(json.contains("\"battery_floor\""))
    #expect(json.contains("\"flag_set_by\" : \"other\""))
}
