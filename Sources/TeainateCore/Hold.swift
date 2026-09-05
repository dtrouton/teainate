import Foundation

public enum HoldKind: String, Codable, Sendable {
    case forever, timer, process
}

public enum HoldSource: String, Codable, Sendable {
    case menu, cli, claude
}

/// What the caller asked for. Converted into caffeinate flags and then a `Hold`.
public struct HoldOptions: Sendable, Equatable {
    public var duration: TimeInterval?
    public var watchedPID: pid_t?
    public var acOnly: Bool
    public var display: Bool
    public var label: String?
    /// Keep the Mac awake even with the lid closed. Needs the sudoers grant; see LidWatch.swift.
    public var lidClosed: Bool
    public var source: HoldSource

    public init(
        duration: TimeInterval? = nil,
        watchedPID: pid_t? = nil,
        acOnly: Bool = false,
        display: Bool = false,
        label: String? = nil,
        lidClosed: Bool = false,
        source: HoldSource
    ) {
        self.duration = duration
        self.watchedPID = watchedPID
        self.acOnly = acOnly
        self.display = display
        self.label = label
        self.lidClosed = lidClosed
        self.source = source
    }

    public var kind: HoldKind {
        if watchedPID != nil { return .process }
        if duration != nil { return .timer }
        return .forever
    }
}

/// Builds caffeinate arguments. Order is fixed so tests and state records are deterministic.
///
/// `-i` prevents idle sleep on any power source; `-s` prevents sleep only on AC, which is
/// how "only while plugged in" works without us monitoring power state.
public func caffeinateFlags(for options: HoldOptions) -> [String] {
    var flags = [options.acOnly ? "-s" : "-i"]
    if options.display { flags.append("-d") }
    if let duration = options.duration {
        flags.append(contentsOf: ["-t", String(Int(min(duration, maxDurationSeconds)))])
    }
    // The watcher of a lid-closed hold owns caffeinate's single `-w` slot (see
    // `watcherChildFlags`); it polls the user's watched pid itself.
    if let pid = options.watchedPID, !options.lidClosed {
        flags.append(contentsOf: ["-w", String(pid)])
    }
    return flags
}

public func makeHoldID(random: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) -> String {
    String(format: "h_%08x", random())
}

public struct Hold: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: HoldKind
    public var label: String?
    public var source: HoldSource
    public var caffeinatePID: pid_t
    public var flags: [String]
    public var startedAt: Date
    public var expiresAt: Date?
    public var watchedPID: pid_t?
    public var display: Bool
    public var acOnly: Bool
    /// True when `caffeinatePID` is a `teainate lid-watch` watcher rather than caffeinate.
    public var lidClosed: Bool
    /// The battery floor this hold was taken with. Never changes after the fact.
    public var batteryFloor: Int?
    /// The kernel's start time for `caffeinatePID` at the moment this hold was recorded.
    /// Compared alongside the PID during reconciliation to close the PID-recycling gap;
    /// nil for records written before this field existed, which then match by name only.
    public var processStartedAt: ProcessStartTime?

    public init(
        id: String, kind: HoldKind, label: String?, source: HoldSource,
        caffeinatePID: pid_t, flags: [String], startedAt: Date, expiresAt: Date?,
        watchedPID: pid_t?, display: Bool, acOnly: Bool,
        lidClosed: Bool = false, batteryFloor: Int? = nil,
        processStartedAt: ProcessStartTime? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.source = source
        self.caffeinatePID = caffeinatePID
        self.flags = flags
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.watchedPID = watchedPID
        self.display = display
        self.acOnly = acOnly
        self.lidClosed = lidClosed
        self.batteryFloor = batteryFloor
        self.processStartedAt = processStartedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, source, flags, display
        case caffeinatePID = "caffeinate_pid"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case watchedPID = "watched_pid"
        case acOnly = "ac_only"
        case lidClosed = "lid_closed"
        case batteryFloor = "battery_floor"
        case processStartedAt = "process_started_at"
    }

    /// Explicit so records written before lid-closed holds existed still decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(HoldKind.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        source = try c.decode(HoldSource.self, forKey: .source)
        caffeinatePID = try c.decode(pid_t.self, forKey: .caffeinatePID)
        flags = try c.decode([String].self, forKey: .flags)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        watchedPID = try c.decodeIfPresent(pid_t.self, forKey: .watchedPID)
        display = try c.decode(Bool.self, forKey: .display)
        acOnly = try c.decode(Bool.self, forKey: .acOnly)
        lidClosed = try c.decodeIfPresent(Bool.self, forKey: .lidClosed) ?? false
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor)
        processStartedAt = try c.decodeIfPresent(ProcessStartTime.self, forKey: .processStartedAt)
    }

    public func remainingSeconds(now: Date) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded()))
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Why the most recent lid-closed hold ended on its own. The hold's record is removed
/// when it ends, so this is the only place `status` can learn the reason.
public struct EndedHold: Codable, Sendable, Equatable {
    public var id: String
    public var label: String?
    public var reason: String
    public var at: Date

    public init(id: String, label: String?, reason: String, at: Date) {
        self.id = id
        self.label = label
        self.reason = reason
        self.at = at
    }
}

/// Everything in `holds.json`. `lidFlagOwned` is true while teainate may have set the
/// kernel sleep-disabled flag; it is the fact orphan cleanup keys off. `lidFlagPendingSince`
/// is set alongside it while an `on` is still in flight (see `lidFlagGracePeriod`)
/// so orphan cleanup running on another process or the app's refresh timer does not mistake
/// a hold that is still being set up for an orphan and clear the flag out from under it.
public struct StoreState: Codable, Sendable, Equatable {
    public var holds: [Hold]
    public var lidFlagOwned: Bool
    public var lidFlagPendingSince: Date?
    public var lastEnded: EndedHold?

    public init(
        holds: [Hold] = [], lidFlagOwned: Bool = false, lidFlagPendingSince: Date? = nil,
        lastEnded: EndedHold? = nil
    ) {
        self.holds = holds
        self.lidFlagOwned = lidFlagOwned
        self.lidFlagPendingSince = lidFlagPendingSince
        self.lastEnded = lastEnded
    }

    enum CodingKeys: String, CodingKey {
        case holds
        case lidFlagOwned = "lid_flag_owned"
        case lidFlagPendingSince = "lid_flag_pending_since"
        case lastEnded = "last_ended"
    }

    /// Accepts both the current object shape and the original bare array.
    public init(from decoder: any Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           c.contains(.holds) {
            holds = try c.decode([Hold].self, forKey: .holds)
            lidFlagOwned = try c.decodeIfPresent(Bool.self, forKey: .lidFlagOwned) ?? false
            lidFlagPendingSince = try c.decodeIfPresent(Date.self, forKey: .lidFlagPendingSince)
            lastEnded = try c.decodeIfPresent(EndedHold.self, forKey: .lastEnded)
        } else {
            holds = try decoder.singleValueContainer().decode([Hold].self)
            lidFlagOwned = false
            lidFlagPendingSince = nil
            lastEnded = nil
        }
    }
}
