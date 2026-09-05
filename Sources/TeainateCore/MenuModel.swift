import Foundation

public enum MenuAction: Sendable, Equatable {
    case holdFor(TimeInterval)
    case holdForever
    /// Set a new-hold default. The value is what the click sets, not a toggle.
    case setDefault(HoldModifier, Bool)
    /// Change a live hold. The value is what the click sets.
    case setModifier(id: String, HoldModifier, Bool)
    case release(String)
    case releaseAll
    case reclaimUntracked
    case installSkill
    case enableLidClosed
    case disableLidClosed
    case setBatteryFloor(Int)
    case quit
    case none
}

public struct MenuItem: Sendable, Equatable {
    public let title: String
    public let action: MenuAction
    public let isEnabled: Bool
    public let isChecked: Bool
    public let isSeparator: Bool
    public let indent: Int
    public let submenu: [MenuItem]

    public init(
        title: String, action: MenuAction = .none, isEnabled: Bool = true,
        isChecked: Bool = false, isSeparator: Bool = false, indent: Int = 0,
        submenu: [MenuItem] = []
    ) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
        self.indent = indent
        self.submenu = submenu
    }

    public static let separator = MenuItem(title: "", isEnabled: false, isSeparator: true)
}

public let menuDurationChoices: [(label: String, seconds: TimeInterval)] = [
    ("15 minutes", 900), ("30 minutes", 1800),
    ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400),
]

public func statusIconIsActive(_ status: Status) -> Bool {
    !status.holds.isEmpty
}

/// The options a "Keep awake for" click produces. A lid-closed default is ignored
/// while the grant is absent — the checkbox is greyed, and a refused hold on every
/// click would be a worse surprise than a hold without the lid.
public func newHoldOptions(duration: TimeInterval?, defaults: NewHoldDefaults, lidEnabled: Bool) -> HoldOptions {
    HoldOptions(
        duration: duration, acOnly: defaults.acOnly, display: defaults.display,
        lidClosed: defaults.lidClosed && lidEnabled, source: .menu
    )
}

/// Five blocks, in the order you act on them: warnings, new holds, what is holding,
/// what else is holding, settings. Every show/enable/check decision is here.
public func buildMenu(
    status: Status,
    defaults: NewHoldDefaults,
    skillState: SkillInstallState,
    now: Date = Date()
) -> [MenuItem] {
    var items: [MenuItem] = []
    let lidEnabled = status.lidClosed.enabled

    // Warnings first: what you most need to know and least expect.
    var notices = status.lidClosed.warnings.map { MenuItem(title: "⚠ \($0)", isEnabled: false) }
    if let ended = status.lidClosed.lastEnded {
        notices.append(MenuItem(title: describeEnded(ended), isEnabled: false))
    }
    if !notices.isEmpty {
        items += notices
        items.append(.separator)
    }

    // New holds: the defaults above the durations, so reading order is action order.
    items.append(MenuItem(title: "New holds", isEnabled: false))
    items += modifierRows(
        display: defaults.display, acOnly: defaults.acOnly,
        lidChecked: defaults.lidClosed && lidEnabled, lidEnabled: lidEnabled, floor: nil, indent: 1
    ) { modifier, value in .setDefault(modifier, value) }
    let durations = menuDurationChoices.map { MenuItem(title: $0.label, action: .holdFor($0.seconds)) }
        + [MenuItem(title: "Indefinitely", action: .holdForever)]
    items.append(MenuItem(title: "Keep awake for", indent: 1, submenu: durations))
    items.append(.separator)

    // Holding: one row per hold, each opening its own live controls.
    items.append(MenuItem(title: "Holding", isEnabled: false))
    if status.holds.isEmpty {
        items.append(MenuItem(title: "Nothing is holding the Mac awake", isEnabled: false, indent: 1))
    }
    for hold in status.holds {
        items.append(MenuItem(
            title: menuTitle(for: hold), indent: 1,
            submenu: holdControls(hold, lidEnabled: lidEnabled, now: now)
        ))
    }
    // Only when it would not duplicate the single Release above it.
    if status.holds.count > 1 {
        items.append(MenuItem(title: "Release all", action: .releaseAll, indent: 1))
    }

    let others = otherHolders(status)
    if !others.isEmpty {
        items.append(.separator)
        items += others
    }

    items.append(.separator)
    items.append(MenuItem(title: "Settings", submenu: lidClosedItems(status) + [.separator, skillItem(skillState)]))
    items.append(MenuItem(title: "Quit teainate", action: .quit))
    return items
}

/// The three modifier checkboxes, for the defaults block and for each hold. Each
/// action carries the value a click sets. Turning lid-closed *off* never needs the
/// grant, so a lid-closed hold's row stays enabled even after the grant is revoked.
private func modifierRows(
    display: Bool, acOnly: Bool, lidChecked: Bool, lidEnabled: Bool, floor: Int?, indent: Int,
    action: (HoldModifier, Bool) -> MenuAction
) -> [MenuItem] {
    let lidUsable = lidEnabled || lidChecked
    var lidTitle = "Allow closing the lid"
    if !lidUsable {
        lidTitle += " (enable in Settings)"
    } else if lidChecked, let floor {
        lidTitle += " (off at \(floor)%)"
    }
    return [
        MenuItem(title: "Keep display on", action: action(.display, !display), isChecked: display, indent: indent),
        MenuItem(title: "Only while plugged in", action: action(.acOnly, !acOnly), isChecked: acOnly, indent: indent),
        MenuItem(
            title: lidTitle, action: lidUsable ? action(.lidClosed, !lidChecked) : .none,
            isEnabled: lidUsable, isChecked: lidChecked, indent: indent
        ),
    ]
}

private func holdControls(_ hold: HoldStatus, lidEnabled: Bool, now: Date) -> [MenuItem] {
    [MenuItem(title: menuDetail(for: hold, now: now), isEnabled: false), .separator]
        + modifierRows(
            display: hold.display, acOnly: hold.acOnly, lidChecked: hold.lidClosed,
            lidEnabled: lidEnabled, floor: hold.batteryFloor, indent: 0
        ) { modifier, value in .setModifier(id: hold.id, modifier, value) }
        + [.separator, MenuItem(title: "Release", action: .release(hold.id))]
}

/// Foreign assertions (read-only) and untracked caffeinate (releasable on request),
/// in one section. Empty when there is nothing to list.
private func otherHolders(_ status: Status) -> [MenuItem] {
    var rows: [MenuItem] = []
    if !status.pmsetAvailable {
        rows.append(MenuItem(title: pmsetUnavailableLine, isEnabled: false, indent: 1))
    } else {
        rows += status.foreignAssertions.map {
            MenuItem(title: "\($0.process) (pid \($0.pid))", isEnabled: false, indent: 1)
        }
    }
    // Actionable, unlike foreign assertions: we can terminate these on request.
    rows += status.untrackedCaffeinate.map {
        MenuItem(title: "\($0.arguments) (pid \($0.pid), not teainate's)", isEnabled: false, indent: 1)
    }
    if !status.untrackedCaffeinate.isEmpty {
        rows.append(MenuItem(title: "Release untracked caffeinate…", action: .reclaimUntracked, indent: 1))
    }
    guard !rows.isEmpty else { return [] }
    return [MenuItem(title: "Also keeping this Mac awake", isEnabled: false)] + rows
}

private func lidClosedItems(_ status: Status) -> [MenuItem] {
    let lid = status.lidClosed
    guard lid.enabled else {
        return [MenuItem(title: "Enable lid-closed holds…", action: .enableLidClosed)]
    }
    let choices = batteryFloorChoices.map { floor in
        MenuItem(title: "\(floor)%", action: .setBatteryFloor(floor), isChecked: floor == lid.batteryFloor)
    }
    let liveLidHold = status.holds.contains(where: \.lidClosed)
    return [
        MenuItem(title: "Lid-closed holds enabled ✓", isEnabled: false),
        MenuItem(title: "Battery floor: \(lid.batteryFloor)%", submenu: choices),
        // Revoking under a live watcher would leave it unable to clear the flag.
        MenuItem(title: "Disable lid-closed holds…", action: .disableLidClosed, isEnabled: !liveLidHold),
    ]
}

private func skillItem(_ state: SkillInstallState) -> MenuItem {
    switch state {
    case .notInstalled:
        return MenuItem(title: "Install Claude Code skill…", action: .installSkill)
    case .stale:
        return MenuItem(title: "Update Claude Code skill", action: .installSkill)
    case .current:
        return MenuItem(title: "Claude Code skill installed ✓", action: .none, isEnabled: false)
    }
}
