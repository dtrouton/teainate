import Testing
import Foundation
@testable import TeainateCore

private func status(
    holds: [HoldStatus] = [],
    foreign: [ForeignAssertion] = [],
    untracked: [UntrackedCaffeinate] = []
) -> Status {
    Status(
        awake: !holds.isEmpty, holds: holds,
        foreignAssertions: foreign, untrackedCaffeinate: untracked
    )
}

private func holdStatus(id: String = "h_1", kind: HoldKind = .forever, remaining: Int? = nil) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: nil, source: .menu,
        expiresAt: nil, remainingSeconds: remaining, display: false, acOnly: false
    )
}

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
