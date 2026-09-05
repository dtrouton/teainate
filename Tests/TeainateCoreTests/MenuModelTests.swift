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
    id: String = "h_1", kind: HoldKind = .forever, label: String? = nil, source: HoldSource = .menu,
    remaining: Int? = nil, expiresAt: Date? = nil, display: Bool = false, acOnly: Bool = false,
    lidClosed: Bool = false, floor: Int? = nil, watched: pid_t? = nil
) -> HoldStatus {
    HoldStatus(
        id: id, kind: kind, label: label, source: source,
        expiresAt: expiresAt, remainingSeconds: remaining, display: display, acOnly: acOnly,
        lidClosed: lidClosed, batteryFloor: floor, watchedPID: watched
    )
}

private let granted = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warnings: [])
private let notGranted = LidClosedStatus(enabled: false, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: nil, warnings: [])

private func menu(
    _ status: Status = status(), defaults: NewHoldDefaults = .off, skill: SkillInstallState = .current
) -> [MenuItem] {
    buildMenu(status: status, defaults: defaults, skillState: skill, now: Date(timeIntervalSince1970: 1_000_000))
}

private func titles(_ items: [MenuItem]) -> [String] {
    items.filter { !$0.isSeparator }.map(\.title)
}

/// Every item at every depth, parents before children.
private func flatten(_ items: [MenuItem]) -> [MenuItem] {
    items.flatMap { [$0] + flatten($0.submenu) }
}

private func item(_ items: [MenuItem], action: MenuAction) -> MenuItem? {
    flatten(items).first { $0.action == action }
}

private func item(_ items: [MenuItem], titled title: String) -> MenuItem? {
    flatten(items).first { $0.title == title }
}

// MARK: Block order

@Test func blocksAppearInActionOrder() {
    let items = menu(status(holds: [holdStatus()], foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]))
    let t = titles(items)
    let newHolds = t.firstIndex(of: "New holds")!
    let holding = t.firstIndex(of: "Holding")!
    let others = t.firstIndex(of: "Also keeping this Mac awake")!
    let settings = t.firstIndex(of: "Settings")!
    #expect(newHolds < holding && holding < others && others < settings)
    #expect(items.last?.action == .quit)
}

@Test func noStatusHeaderRow() {
    let t = titles(menu(status(holds: [holdStatus(kind: .timer, remaining: 2520)])))
    #expect(t.first == "New holds")
    #expect(!t.contains { $0.hasPrefix("●") || $0.hasPrefix("○") })
}

// MARK: Warnings

@Test func warningsLeadTheMenu() {
    let warned = LidClosedStatus(enabled: true, flagSet: true, flagSetBy: "teainate", batteryFloor: 15, lastEnded: nil,
                                 warnings: ["first warning", "second warning"])
    let t = titles(menu(status(lid: warned)))
    #expect(t[0] == "⚠ first warning")
    #expect(t[1] == "⚠ second warning")
    #expect(t[2] == "New holds")
}

@Test func lastEndedReasonLeadsTheMenu() {
    let ended = EndedHold(id: "h_x", label: "build", reason: "battery 14% at floor 15%", at: Date())
    let lid = LidClosedStatus(enabled: true, flagSet: false, flagSetBy: nil, batteryFloor: 15, lastEnded: ended, warnings: [])
    #expect(titles(menu(status(lid: lid))).first == "Last lid-closed hold (build) ended: battery 14% at floor 15%")
}

// MARK: New holds

@Test func newHoldCheckboxesReflectDefaults() {
    let items = menu(status(lid: granted), defaults: NewHoldDefaults(display: true, acOnly: false, lidClosed: true))
    // The action carries the value a click sets: the opposite of the current state.
    #expect(item(items, action: .setDefault(.display, false))?.isChecked == true)
    #expect(item(items, action: .setDefault(.acOnly, true))?.isChecked == false)
    #expect(item(items, action: .setDefault(.lidClosed, false))?.isChecked == true)
}

@Test func newHoldLidCheckboxIsGreyedAndUncheckedWithoutTheGrant() throws {
    let items = menu(status(lid: notGranted), defaults: NewHoldDefaults(lidClosed: true))
    let row = try #require(item(items, titled: "Allow closing the lid (enable in Settings)"))
    #expect(row.isEnabled == false)
    #expect(row.isChecked == false)
    #expect(row.action == .none)
    #expect(item(items, action: .setDefault(.lidClosed, false)) == nil)
}

@Test func durationsLiveInAKeepAwakeForSubmenu() throws {
    let items = menu()
    let row = try #require(item(items, titled: "Keep awake for"))
    #expect(row.isEnabled)
    #expect(row.submenu.map(\.action) == menuDurationChoices.map { .holdFor($0.seconds) } + [.holdForever])
    #expect(row.submenu.last?.title == "Indefinitely")
    #expect(!items.contains { $0.action == .holdForever })   // not at top level
}

@Test func newHoldOptionsApplyDefaultsButNeverLidWithoutTheGrant() {
    let defaults = NewHoldDefaults(display: true, acOnly: true, lidClosed: true)
    let granted = newHoldOptions(duration: 900, defaults: defaults, lidEnabled: true)
    #expect(granted.duration == 900 && granted.display && granted.acOnly && granted.lidClosed)
    #expect(granted.source == .menu)
    let revoked = newHoldOptions(duration: nil, defaults: defaults, lidEnabled: false)
    #expect(revoked.duration == nil && revoked.display && revoked.acOnly && !revoked.lidClosed)
}

// MARK: Holding

@Test func emptyHoldingBlockSaysSo() {
    let t = titles(menu())
    #expect(t.contains("Nothing is holding the Mac awake"))
    #expect(item(menu(), action: .releaseAll) == nil)
}

@Test func eachHoldIsARowWithItsOwnControls() throws {
    let hold = holdStatus(id: "h_a", kind: .timer, label: "build", remaining: 2520,
                          expiresAt: Date(timeIntervalSince1970: 1_002_520), display: true)
    let items = menu(status(holds: [hold], lid: granted))
    let row = try #require(item(items, titled: "build · 42 min left · display on"))
    #expect(row.indent == 1)
    let sub = row.submenu
    #expect(sub.first?.title.hasPrefix("until ") == true)
    #expect(sub.first?.isEnabled == false)
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .display, false) && $0.isChecked })
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .acOnly, true) && !$0.isChecked })
    #expect(sub.contains { $0.action == .setModifier(id: "h_a", .lidClosed, true) && !$0.isChecked })
    #expect(sub.last?.action == .release("h_a"))
    #expect(sub.last?.title == "Release")
}

@Test func holdCheckboxesReflectTheHoldNotTheDefaults() throws {
    let hold = holdStatus(id: "h_a", display: false, acOnly: true)
    let items = menu(status(holds: [hold], lid: granted), defaults: NewHoldDefaults(display: true, acOnly: false))
    let row = try #require(item(items, titled: menuTitle(for: hold)))
    #expect(row.submenu.first { $0.action == .setModifier(id: "h_a", .display, true) }?.isChecked == false)
    #expect(row.submenu.first { $0.action == .setModifier(id: "h_a", .acOnly, false) }?.isChecked == true)
}

@Test func lidHoldRowShowsTheFloorAndCanAlwaysBeTurnedOff() throws {
    let hold = holdStatus(id: "h_l", lidClosed: true, floor: 15)
    // Grant revoked after the hold was taken: turning lid-closed off needs no grant.
    let items = menu(status(holds: [hold], lid: notGranted))
    let row = try #require(item(items, titled: menuTitle(for: hold)))
    let lid = try #require(row.submenu.first { $0.action == .setModifier(id: "h_l", .lidClosed, false) })
    #expect(lid.isEnabled)
    #expect(lid.isChecked)
    #expect(lid.title == "Allow closing the lid (off at 15%)")
}

@Test func plainHoldLidRowIsGreyedWithoutTheGrant() throws {
    let hold = holdStatus(id: "h_p")
    let row = try #require(item(menu(status(holds: [hold], lid: notGranted)), titled: menuTitle(for: hold)))
    let lid = try #require(row.submenu.first { $0.title == "Allow closing the lid (enable in Settings)" })
    #expect(!lid.isEnabled)
    #expect(lid.action == .none)
}

@Test func detailRowNamesTheWatchedProcess() throws {
    let hold = holdStatus(id: "h_c", kind: .process, source: .claude, watched: 6707)
    let row = try #require(item(menu(status(holds: [hold])), titled: "Claude session · until it exits"))
    #expect(row.submenu.first?.title == "until pid 6707 exits")
}

@Test func releaseAllAppearsOnlyWithTwoOrMoreHolds() {
    #expect(item(menu(status(holds: [holdStatus(id: "h_a")])), action: .releaseAll) == nil)
    let two = menu(status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b")]))
    #expect(item(two, action: .releaseAll) != nil)
    #expect(item(two, action: .release("h_a")) != nil)
    #expect(item(two, action: .release("h_b")) != nil)
}

// MARK: Also keeping this Mac awake

@Test func foreignAssertionsAppearWhenPresent() {
    let t = titles(menu(status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")])))
    #expect(t.contains("Also keeping this Mac awake"))
    #expect(t.contains("Claude (pid 640)"))
}

@Test func othersSectionOmittedWhenNothingToList() {
    let t = titles(menu())
    #expect(!t.contains("Also keeping this Mac awake"))
    #expect(item(menu(), action: .reclaimUntracked) == nil)
}

@Test func pmsetFailureIsShownInTheOthersSection() {
    let t = titles(menu(status(pmsetAvailable: false)))
    #expect(t.contains("Also keeping this Mac awake"))
    #expect(t.contains("Other sleep assertions: unavailable (pmset failed)"))
}

@Test func untrackedCaffeinateIsListedWithItsFlagsAndAReclaimAction() throws {
    let items = menu(status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]))
    #expect(titles(items).contains("Also keeping this Mac awake"))
    #expect(titles(items).contains("caffeinate -i (pid 555, not teainate's)"))
    let reclaim = try #require(item(items, action: .reclaimUntracked))
    #expect(reclaim.title == "Release untracked caffeinate…")
}

// MARK: Settings

@Test func settingsSubmenuOffersEnableWhenNotGranted() throws {
    let settings = try #require(item(menu(status(lid: notGranted)), titled: "Settings"))
    #expect(settings.submenu.contains { $0.action == .enableLidClosed && $0.title == "Enable lid-closed holds…" })
    #expect(!settings.submenu.contains { $0.action == .disableLidClosed })
    #expect(!settings.submenu.contains { $0.title.hasPrefix("Battery floor") })
}

@Test func settingsSubmenuOffersFloorAndDisableWhenGranted() throws {
    let settings = try #require(item(menu(status(lid: granted)), titled: "Settings"))
    #expect(settings.submenu.contains { $0.title == "Lid-closed holds enabled ✓" && !$0.isEnabled })
    let floor = try #require(settings.submenu.first { $0.title == "Battery floor: 15%" })
    #expect(floor.submenu.map(\.action) == batteryFloorChoices.map { .setBatteryFloor($0) })
    #expect(floor.submenu.first { $0.action == .setBatteryFloor(15) }?.isChecked == true)
    #expect(floor.submenu.first { $0.action == .setBatteryFloor(30) }?.isChecked == false)
    #expect(settings.submenu.first { $0.action == .disableLidClosed }?.isEnabled == true)
}

@Test func disableIsGreyedWhileALidHoldIsLive() throws {
    let settings = try #require(item(menu(status(holds: [holdStatus(lidClosed: true)], lid: granted)), titled: "Settings"))
    #expect(settings.submenu.first { $0.action == .disableLidClosed }?.isEnabled == false)
}

@Test func skillRowLivesInSettings() throws {
    let install = try #require(item(menu(skill: .notInstalled), titled: "Settings")).submenu.first { $0.action == .installSkill }
    #expect(install?.title == "Install Claude Code skill…")
    #expect(install?.isEnabled == true)

    let current = try #require(item(menu(skill: .current), titled: "Settings")).submenu.first { $0.title.contains("Claude Code skill") }
    #expect(current?.title == "Claude Code skill installed ✓")
    #expect(current?.isEnabled == false)

    let stale = try #require(item(menu(skill: .stale("gone")), titled: "Settings")).submenu.first { $0.action == .installSkill }
    #expect(stale?.title == "Update Claude Code skill")
    #expect(item(menu(skill: .notInstalled), action: .installSkill)?.title != nil)
    #expect(!menu(skill: .notInstalled).contains { $0.action == .installSkill })   // not at top level
}

// MARK: Invariants

// MenuRenderer relies solely on `isEnabled`, so this layer must never emit an enabled
// row that does nothing. Rows that open a submenu are the one exception: they have no
// action of their own but must stay enabled for the submenu to open.
@Test func actionlessItemsAreNeverEnabledAtAnyDepth() {
    let statuses = [
        status(),
        status(holds: [holdStatus(id: "h_a"), holdStatus(id: "h_b", kind: .timer, remaining: 90, expiresAt: Date())], lid: granted),
        status(holds: [holdStatus(id: "h_l", lidClosed: true, floor: 15)], lid: notGranted),
        status(foreign: [ForeignAssertion(pid: 640, process: "Claude", type: "NoIdleSleepAssertion")]),
        status(untracked: [UntrackedCaffeinate(pid: 555, arguments: "caffeinate -i")]),
        status(pmsetAvailable: false),
    ]
    let skillStates: [SkillInstallState] = [.notInstalled, .current, .stale("gone")]
    let defaults = [NewHoldDefaults.off, NewHoldDefaults(display: true, acOnly: true, lidClosed: true)]

    for status in statuses {
        for skillState in skillStates {
            for defaultSet in defaults {
                let items = buildMenu(status: status, defaults: defaultSet, skillState: skillState)
                for item in flatten(items) where item.action == .none && item.submenu.isEmpty {
                    #expect(!item.isEnabled, "'\(item.title)' has action .none but isEnabled == true")
                }
                for item in flatten(items) where !item.submenu.isEmpty {
                    #expect(item.isEnabled, "'\(item.title)' opens a submenu but is disabled")
                }
            }
        }
    }
}

@Test func quitIsAlwaysLast() {
    #expect(menu().last?.action == .quit)
    #expect(menu(status(holds: [holdStatus()], lid: granted)).last?.action == .quit)
}

@Test func iconIsActiveOnlyWhenHoldsExist() {
    #expect(statusIconIsActive(status()) == false)
    #expect(statusIconIsActive(status(holds: [holdStatus()])) == true)
}
