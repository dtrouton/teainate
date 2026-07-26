import Foundation

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

    if !status.foreignAssertions.isEmpty {
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
        lines.append("  (release with: teainate off --untracked)")
    }

    return lines.joined(separator: "\n")
}

/// A one-line description of a hold.
///
/// A label never replaces the remaining time — "how much longer do I have?" is the
/// question this tool exists to answer, so a labelled timer shows both:
/// `build — 42 min left`.
public func describe(_ hold: HoldStatus) -> String {
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
    if !modifiers.isEmpty { parts.append("(\(modifiers.joined(separator: ", ")))") }

    parts.append("[\(hold.id)]")
    return parts.joined(separator: " ")
}

private func defaultLabel(for hold: HoldStatus) -> String {
    switch hold.kind {
    case .forever:
        return "indefinitely"
    case .timer:
        guard let remaining = hold.remainingSeconds else { return "timed" }
        return "\(remaining / 60) min left"
    case .process:
        return "until session exits"
    }
}
