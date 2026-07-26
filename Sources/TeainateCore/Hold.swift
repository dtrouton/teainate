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
    public var source: HoldSource

    public init(
        duration: TimeInterval? = nil,
        watchedPID: pid_t? = nil,
        acOnly: Bool = false,
        display: Bool = false,
        label: String? = nil,
        source: HoldSource
    ) {
        self.duration = duration
        self.watchedPID = watchedPID
        self.acOnly = acOnly
        self.display = display
        self.label = label
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
        flags.append(contentsOf: ["-t", String(Int(duration))])
    }
    if let pid = options.watchedPID {
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

    public init(
        id: String, kind: HoldKind, label: String?, source: HoldSource,
        caffeinatePID: pid_t, flags: [String], startedAt: Date, expiresAt: Date?,
        watchedPID: pid_t?, display: Bool, acOnly: Bool
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
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, source, flags, display
        case caffeinatePID = "caffeinate_pid"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case watchedPID = "watched_pid"
        case acOnly = "ac_only"
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
