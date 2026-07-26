import Foundation

public enum MenuAction: Sendable, Equatable {
    case holdFor(TimeInterval)
    case holdForever
    case toggleACOnly
    case toggleDisplay
    case release(String)
    case releaseAll
    case reclaimUntracked
    case installSkill
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

    public init(
        title: String, action: MenuAction = .none, isEnabled: Bool = true,
        isChecked: Bool = false, isSeparator: Bool = false, indent: Int = 0
    ) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
        self.indent = indent
    }

    public static let separator = MenuItem(title: "", isEnabled: false, isSeparator: true)
}

/// Modifiers apply to the *next* activation; they never retroactively change a running hold.
public struct MenuPreferences: Sendable, Equatable {
    public var acOnly: Bool
    public var display: Bool

    public init(acOnly: Bool = false, display: Bool = false) {
        self.acOnly = acOnly
        self.display = display
    }
}

public let menuDurationChoices: [(label: String, seconds: TimeInterval)] = [
    ("15 minutes", 900), ("30 minutes", 1800),
    ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400),
]

public func statusIconIsActive(_ status: Status) -> Bool {
    !status.holds.isEmpty
}

public func buildMenu(
    status: Status,
    preferences: MenuPreferences,
    skillState: SkillInstallState
) -> [MenuItem] {
    var items: [MenuItem] = []

    items.append(MenuItem(title: headerTitle(status), isEnabled: false))
    items.append(.separator)

    for choice in menuDurationChoices {
        items.append(MenuItem(title: "Keep awake for \(choice.label)", action: .holdFor(choice.seconds)))
    }
    items.append(MenuItem(title: "Keep awake indefinitely", action: .holdForever))
    items.append(.separator)

    items.append(MenuItem(
        title: "Only while plugged in", action: .toggleACOnly, isChecked: preferences.acOnly
    ))
    items.append(MenuItem(
        title: "Keep display on", action: .toggleDisplay, isChecked: preferences.display
    ))

    if !status.holds.isEmpty {
        items.append(.separator)
        items.append(MenuItem(title: "Active holds", isEnabled: false))
        for hold in status.holds {
            items.append(MenuItem(
                title: "Release \(describe(hold))", action: .release(hold.id), indent: 1
            ))
        }
        items.append(MenuItem(title: "Turn off all", action: .releaseAll))
    }

    if !status.foreignAssertions.isEmpty {
        items.append(.separator)
        items.append(MenuItem(title: "Also keeping this Mac awake", isEnabled: false))
        for assertion in status.foreignAssertions {
            items.append(MenuItem(
                title: "\(assertion.process) (pid \(assertion.pid))", isEnabled: false, indent: 1
            ))
        }
    }

    // Actionable, unlike foreign assertions: we can terminate these on request.
    if !status.untrackedCaffeinate.isEmpty {
        items.append(.separator)
        items.append(MenuItem(title: "Not managed by teainate", isEnabled: false))
        for process in status.untrackedCaffeinate {
            items.append(MenuItem(
                title: "pid \(process.pid) — \(process.arguments)", isEnabled: false, indent: 1
            ))
        }
        items.append(MenuItem(
            title: "Release untracked caffeinate…", action: .reclaimUntracked
        ))
    }

    items.append(.separator)
    items.append(skillItem(skillState))
    items.append(.separator)
    items.append(MenuItem(title: "Quit teainate", action: .quit))

    return items
}

private func headerTitle(_ status: Status) -> String {
    guard let first = status.holds.first else { return "○ Off" }
    if status.holds.count > 1 {
        return "● Awake — \(status.holds.count) holds"
    }
    return "● Awake — \(describe(first))"
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
