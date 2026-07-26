import Testing
import Foundation
@testable import TeainateCore

private func status(
    awake: Bool = true,
    holds: [HoldStatus] = [],
    foreign: [ForeignAssertion] = [],
    untracked: [UntrackedCaffeinate] = []
) -> Status {
    Status(awake: awake, holds: holds, foreignAssertions: foreign, untrackedCaffeinate: untracked)
}

private func holdStatus(
    id: String = "h_1", kind: HoldKind = .forever, label: String? = nil,
    remaining: Int? = nil, display: Bool = false, acOnly: Bool = false
) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: label, source: .cli,
        expiresAt: nil, remainingSeconds: remaining, display: display, acOnly: acOnly
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

@Test func rendersUntrackedCaffeinateWithFlags() {
    let text = renderStatus(Status(
        awake: false, holds: [], foreignAssertions: [],
        untrackedCaffeinate: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i -t 300")]
    ))
    #expect(text.contains("not managed by teainate"))
    #expect(text.contains("caffeinate -i -t 300"))
    #expect(text.contains("555"))
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
