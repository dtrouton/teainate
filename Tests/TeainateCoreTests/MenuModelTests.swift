import Testing
import Foundation
@testable import TeainateCore

private func status(
    holds: [HoldStatus] = [],
    foreign: [ForeignAssertion] = [],
    untracked: [UntrackedCaffeinate] = [],
    lid: LidClosedStatus = .unavailable,
    pmsetAvailable: Bool = true
) -> Status {
    Status(
        awake: !holds.isEmpty, holds: holds,
        foreignAssertions: foreign, untrackedCaffeinate: untracked, lidClosed: lid,
        pmsetAvailable: pmsetAvailable
    )
}

private func holdStatus(
    id: String = "h_1", kind: HoldKind = .forever, remaining: Int? = nil, lidClosed: Bool = false
) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: nil, source: .menu,
        expiresAt: nil, remainingSeconds: remaining, display: false, acOnly: false,
        lidClosed: lidClosed
    )
}

private let granted = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)
private let notGranted = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warning: nil)

private func titles(_ items: [MenuItem]) -> [String] {
    items.filter { !$0.isSeparator }.map(\.title)
}

@Test func idleMenuOffersDurations() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).contains("Keep awake indefinitely"))
    #expect(items.contains { $0.action == .holdFor(900) })
    #expect(items.contains { $0.action == .holdFor(14400) })
}

@Test func idleMenuHidesActiveHoldsSection() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(!titles(items).contains("Active holds"))
    #expect(!items.contains { $0.action == .releaseAll })
}

@Test func activeMenuListsHoldsWithReleaseActions() {
    let items = buildMenu(
        status: status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b")]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).contains("Active holds"))
    #expect(items.contains { $0.action == .release("h_a") })
    #expect(items.contains { $0.action == .release("h_b") })
    #expect(items.contains { $0.action == .releaseAll })
}

// This pair is what stops the two surfaces drifting apart: the menu row is click-to-release
// so the id would be noise, but the CLI still needs it for `off --id`.
@Test func menuReleaseRowOmitsHoldID() {
    let items = buildMenu(
        status: status(holds: [holdStatus(id: "h_build")]),
        preferences: MenuPreferences(), skillState: .current
    )
    let releaseItem = items.first { $0.action == .release("h_build") }
    #expect(releaseItem?.title.contains("[h_build]") == false)
}

@Test func cliStatusStillIncludesHoldID() {
    let text = renderStatus(status(holds: [holdStatus(id: "h_build")]))
    #expect(text.contains("[h_build]"))
}

@Test func headerReflectsRemainingTime() {
    let items = buildMenu(
        status: status(holds: [holdStatus(kind: .timer, remaining: 2520)]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).first?.contains("42 min left") == true)
}

// 119 is not a multiple of 60: floor-division would read "1 min left" here, off by
// nearly a full minute. The header must round instead.
@Test func headerRoundsRemainingTimeRatherThanFlooring() {
    let items = buildMenu(
        status: status(holds: [holdStatus(kind: .timer, remaining: 119)]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).first?.contains("2 min left") == true)
}

@Test func headerShowsLessThanAMinuteBelowSixtySeconds() {
    let items = buildMenu(
        status: status(holds: [holdStatus(kind: .timer, remaining: 30)]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).first?.contains("less than a minute left") == true)
}

@Test func headerSaysOffWhenIdle() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).first?.contains("Off") == true)
}

@Test func modifierChecksReflectPreferences() {
    let items = buildMenu(
        status: status(),
        preferences: MenuPreferences(acOnly: true, display: false),
        skillState: .current
    )
    let acItem = items.first { $0.action == .toggleACOnly }
    let displayItem = items.first { $0.action == .toggleDisplay }
    #expect(acItem?.isChecked == true)
    #expect(displayItem?.isChecked == false)
}

@Test func foreignAssertionsAppearWhenPresent() {
    let items = buildMenu(
        status: status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).contains("Also keeping this Mac awake"))
    #expect(titles(items).contains { $0.contains("Claude") })
}

@Test func foreignSectionOmittedWhenEmpty() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(!titles(items).contains("Also keeping this Mac awake"))
}

@Test func menuShowsUnavailableAssertions() {
    let items = buildMenu(status: status(pmsetAvailable: false), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).contains("Other sleep assertions: unavailable (pmset failed)"))
}

@Test func untrackedSectionShowsFlagsAndOffersReclaim() {
    let items = buildMenu(
        status: status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]),
        preferences: MenuPreferences(), skillState: .current
    )
    #expect(titles(items).contains("Not managed by teainate"))
    #expect(titles(items).contains { $0.contains("caffeinate -i") })
    #expect(items.contains { $0.action == .reclaimUntracked })
}

@Test func untrackedSectionOmittedWhenEmpty() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(!titles(items).contains("Not managed by teainate"))
    #expect(!items.contains { $0.action == .reclaimUntracked })
}

@Test func skillItemOffersInstallWhenAbsent() throws {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .notInstalled)
    let item = try #require(items.first { $0.action == .installSkill })
    #expect(item.title == "Install Claude Code skill…")
    #expect(item.isEnabled)
}

@Test func skillItemIsDisabledWhenCurrent() throws {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    let item = try #require(items.first { $0.title.contains("Claude Code skill") })
    #expect(item.title == "Claude Code skill installed ✓")
    #expect(!item.isEnabled)
    #expect(item.action == .none)
}

@Test func skillItemOffersUpdateWhenStale() throws {
    let items = buildMenu(
        status: status(), preferences: MenuPreferences(),
        skillState: .stale("recorded teainate path no longer exists")
    )
    let item = try #require(items.first { $0.action == .installSkill })
    #expect(item.title == "Update Claude Code skill")
    #expect(item.isEnabled)
}

// MenuRenderer relies solely on `isEnabled` (no `action != .none` safety net of its own),
// so this is the layer that must guarantee the model never emits an enabled-but-actionless
// row — otherwise a future item would render as clickable but silently do nothing.
@Test func actionlessItemsAreNeverEnabled() {
    let statuses = [
        status(),
        status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b")]),
        status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]),
        status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]),
        status(
            holds: [holdStatus(id: "h_a")],
            foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")],
            untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]
        ),
    ]
    let skillStates: [SkillInstallState] = [.notInstalled, .current, .stale("gone")]

    for status in statuses {
        for skillState in skillStates {
            let items = buildMenu(status: status, preferences: MenuPreferences(), skillState: skillState)
            for item in items where item.action == .none {
                #expect(!item.isEnabled, "'\(item.title)' has action .none but isEnabled == true")
            }
        }
    }
}

@Test func quitIsAlwaysLast() {
    let items = buildMenu(status: status(), preferences: MenuPreferences(), skillState: .current)
    #expect(items.last?.action == .quit)
}

@Test func iconIsActiveOnlyWhenHoldsExist() {
    #expect(statusIconIsActive(status()) == false)
    #expect(statusIconIsActive(status(holds: [holdStatus()])) == true)
}

@Test func lidModifierIsGreyedUntilGranted() {
    let items = buildMenu(status: status(lid: notGranted), preferences: MenuPreferences(lidClosed: true), skillState: .current)
    let row = items.first { $0.action == .toggleLidClosed }
    #expect(row?.isEnabled == false)
    #expect(row?.isChecked == false)
    #expect(row?.title == "Allow closing the lid (enable below)")
}

@Test func lidModifierChecksWhenGrantedAndPreferred() {
    let items = buildMenu(status: status(lid: granted), preferences: MenuPreferences(lidClosed: true), skillState: .current)
    let row = items.first { $0.action == .toggleLidClosed }
    #expect(row?.isEnabled == true)
    #expect(row?.isChecked == true)
    #expect(row?.title == "Allow closing the lid")
}

@Test func offersEnableWhenNotGranted() {
    let items = buildMenu(status: status(lid: notGranted), preferences: MenuPreferences(), skillState: .current)
    #expect(items.contains { $0.action == .enableLidClosed && $0.title == "Enable lid-closed holds…" })
    #expect(!items.contains { $0.action == .disableLidClosed })
    #expect(!items.contains { $0.title.hasPrefix("Battery floor") })
}

@Test func offersFloorAndDisableWhenGranted() {
    let items = buildMenu(status: status(lid: granted), preferences: MenuPreferences(), skillState: .current)
    #expect(items.contains { $0.title == "Lid-closed holds enabled ✓" && !$0.isEnabled })
    let floor = items.first { $0.title == "Battery floor: 15%" }
    #expect(floor?.submenu.map(\.action) == batteryFloorChoices.map { .setBatteryFloor($0) })
    #expect(floor?.submenu.first { $0.action == .setBatteryFloor(15) }?.isChecked == true)
    #expect(floor?.submenu.first { $0.action == .setBatteryFloor(30) }?.isChecked == false)
    #expect(items.first { $0.action == .disableLidClosed }?.isEnabled == true)
}

@Test func disableIsGreyedWhileALidHoldIsLive() {
    let items = buildMenu(status: status(holds: [holdStatus(lidClosed: true)], lid: granted),
                          preferences: MenuPreferences(), skillState: .current)
    #expect(items.first { $0.action == .disableLidClosed }?.isEnabled == false)
}

@Test func headerShowsWarningLine() {
    let warned = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15, lastEnded: nil,
                                 warning: "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0")
    let items = buildMenu(status: status(lid: warned), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items)[1].hasPrefix("⚠ The sleep-disabled flag is set"))
}

@Test func showsLastEndedReason() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warning: nil)
    let items = buildMenu(status: status(lid: lid), preferences: MenuPreferences(), skillState: .current)
    #expect(titles(items).contains("Last lid-closed hold (build) ended: battery 14% at floor 15%"))
}
