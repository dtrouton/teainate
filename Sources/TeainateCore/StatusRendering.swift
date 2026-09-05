import Foundation

/// Shown in place of the foreign-assertions section when `pmset -g assertions`
/// itself failed to run — used by both the CLI's `renderStatus` and the menu's
/// `buildMenu` so the wording exists once.
public let pmsetUnavailableLine = "Other sleep assertions: unavailable (pmset failed)"

public func renderStatus(_ status: Status) -> String {
    var lines: [String] = []

    if status.holds.isEmpty {
        lines.append("○ Not holding the Mac awake")
    } else {
        lines.append("● Holding the Mac awake (\(status.holds.count) hold\(status.holds.count == 1 ? "" : "s"))")
        for hold in status.holds {
            lines.append("  \(describe(hold))")
        }
    }

    if !status.pmsetAvailable {
        lines.append("")
        lines.append(pmsetUnavailableLine)
    } else if !status.foreignAssertions.isEmpty {
        lines.append("")
        lines.append("Also keeping this Mac awake:")
        for assertion in status.foreignAssertions {
            lines.append("  \(assertion.process) (pid \(assertion.pid)) — \(assertion.type)")
        }
    }

    // Shown separately from foreign assertions: these carry their command line,
    // so the user can see what kind of hold an unmanaged process represents.
    if !status.untrackedCaffeinate.isEmpty {
        lines.append("")
        lines.append("caffeinate processes not managed by teainate:")
        for process in status.untrackedCaffeinate {
            lines.append("  pid \(process.pid) — \(process.arguments)")
        }
        lines.append("  (not teainate's — \"teainate off --untracked\" would terminate them)")
    }

    let lid = status.lidClosed
    lines.append("")
    for warning in lid.warnings {
        lines.append("⚠ \(warning)")
    }
    if let ended = lid.lastEnded {
        lines.append(describeEnded(ended))
    }
    lines.append(lid.enabled
        ? "Lid-closed holds: enabled (battery floor \(lid.batteryFloor)%)"
        : "Lid-closed holds: not enabled — enable from the Teainate menu")

    return lines.joined(separator: "\n")
}

/// One line explaining why the most recent lid-closed hold ended on its own.
public func describeEnded(_ ended: EndedHold) -> String {
    let name = ended.label.map { " (\($0))" } ?? ""
    return "Last lid-closed hold\(name) ended: \(ended.reason)"
}

/// A one-line description of a hold for the CLI.
///
/// A label never replaces the remaining time — "how much longer do I have?" is the
/// question this tool exists to answer, so a labelled timer shows both:
/// `build — 42 min left`.
///
/// `includingID` exists because the two surfaces need different things: in the CLI the
/// id is essential (you need it for `off --id`), but in the menu you click a row to
/// release it, so the id is noise.
public func describe(_ hold: HoldStatus, includingID: Bool = true) -> String {
    var parts: [String] = []

    let lifetime = defaultLabel(for: hold)
    if let label = hold.label {
        parts.append(hold.kind == .forever ? label : "\(label) — \(lifetime)")
    } else {
        parts.append(lifetime)
    }

    let modifiers = modifierFacts(for: hold)
    if !modifiers.isEmpty { parts.append("(\(modifiers.joined(separator: ", ")))") }

    if includingID { parts.append("[\(hold.id)]") }
    return parts.joined(separator: " ")
}

/// The menu row for a hold: what it is and how it is set, as facts joined with middle
/// dots — `build · 42 min left · display on · lid ok`. The row opens the hold's
/// controls, so there is no id and no verb. A Claude session with no label is named
/// as such, because "until session exits" alone does not say whose.
public func menuTitle(for hold: HoldStatus) -> String {
    var facts: [String] = []
    let subject = hold.label ?? (hold.source == .claude ? "Claude session" : nil)
    if let subject { facts.append(subject) }
    switch hold.kind {
    case .forever:
        if subject == nil { facts.append("indefinitely") }
    case .process:
        facts.append(subject == nil ? "until session exits" : "until it exits")
    case .timer:
        facts.append(defaultLabel(for: hold))
    }
    facts += modifierFacts(for: hold)
    return facts.joined(separator: " · ")
}

/// The precise end of a hold, for the first row of its submenu: `until 3:12 PM`,
/// `until pid 6707 exits`, or `indefinitely`. The date joins the time once the end is
/// not today. `calendar` and `locale` are parameters so tests can pin them.
public func menuDetail(
    for hold: HoldStatus, now: Date, calendar: Calendar = .current, locale: Locale = .current
) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .process:
        guard let pid = hold.watchedPID else { return "until the watched process exits" }
        return "until pid \(pid) exits"
    case .timer:
        guard let end = hold.expiresAt else { return "timed" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(end, inSameDayAs: now) ? .none : .medium
        return "until \(formatter.string(from: end))"
    }
}

/// The modifier facts both surfaces list, in one order.
private func modifierFacts(for hold: HoldStatus) -> [String] {
    var facts: [String] = []
    if hold.display { facts.append("display on") }
    if hold.acOnly { facts.append("only while plugged in") }
    if hold.lidClosed {
        facts.append("lid ok")
        if let floor = hold.batteryFloor { facts.append("off at \(floor)%") }
    }
    return facts
}

private func defaultLabel(for hold: HoldStatus) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .timer:
        guard let remaining = hold.remainingSeconds else { return "timed" }
        return "\(remainingLabel(seconds: remaining)) left"
    case .process:
        return "until session exits"
    }
}

/// Minutes under an hour, hours and minutes under two days, days and hours beyond.
/// Zero trailing units are dropped ("2 h", not "2 h 0 min"). Minutes are rounded;
/// hours and days truncate, so a long hold under-reports slightly rather than
/// claiming time it does not have, and nothing ever reads as spent while it lasts.
func remainingLabel(seconds: Int) -> String {
    if seconds < 60 { return "less than a minute" }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60, spareMinutes = minutes % 60
    if hours < 48 {
        return spareMinutes == 0 ? "\(hours) h" : "\(hours) h \(spareMinutes) min"
    }
    let days = hours / 24, spareHours = hours % 24
    return spareHours == 0 ? "\(days) days" : "\(days) days \(spareHours) h"
}
