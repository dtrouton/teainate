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
    if let warning = lid.warning {
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

/// A one-line description of a hold.
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

    var modifiers: [String] = []
    if hold.display { modifiers.append("display on") }
    if hold.acOnly { modifiers.append("only while plugged in") }
    if hold.lidClosed {
        modifiers.append("lid ok")
        if let floor = hold.batteryFloor { modifiers.append("off at \(floor)%") }
    }
    if !modifiers.isEmpty { parts.append("(\(modifiers.joined(separator: ", ")))") }

    if includingID { parts.append("[\(hold.id)]") }
    return parts.joined(separator: " ")
}

private func defaultLabel(for hold: HoldStatus) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .timer:
        guard let remaining = hold.remainingSeconds else { return "timed" }
        if remaining < 60 { return "less than a minute left" }
        return "\(Int((Double(remaining) / 60).rounded())) min left"
    case .process:
        return "until session exits"
    }
}
