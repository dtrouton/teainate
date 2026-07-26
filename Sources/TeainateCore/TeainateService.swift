import Foundation

public enum ServiceError: Error, Equatable {
    case noClaudeAncestor
    case spawnFailed(String)
}

public struct HoldStatus: Codable, Sendable, Equatable {
    public let id: String
    public let kind: HoldKind
    public let label: String?
    public let source: HoldSource
    public let expiresAt: Date?
    public let remainingSeconds: Int?
    public let display: Bool
    public let acOnly: Bool

    // Explicit public init: the memberwise one is internal, and the CLI target
    // constructs these from outside the module.
    public init(
        id: String, kind: HoldKind, label: String?, source: HoldSource,
        expiresAt: Date?, remainingSeconds: Int?, display: Bool, acOnly: Bool
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.source = source
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.display = display
        self.acOnly = acOnly
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, source, display
        case expiresAt = "expires_at"
        case remainingSeconds = "remaining_seconds"
        case acOnly = "ac_only"
    }
}

public struct Status: Codable, Sendable, Equatable {
    public let awake: Bool
    public let holds: [HoldStatus]
    public let foreignAssertions: [ForeignAssertion]

    // Explicit public init: the app target constructs an empty Status as a fallback.
    public init(awake: Bool, holds: [HoldStatus], foreignAssertions: [ForeignAssertion]) {
        self.awake = awake
        self.holds = holds
        self.foreignAssertions = foreignAssertions
    }

    enum CodingKeys: String, CodingKey {
        case awake, holds
        case foreignAssertions = "foreign_assertions"
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// The single entry point both clients use. Holds no state of its own —
/// everything lives in the store, so the CLI and the app always agree.
public struct TeainateService: Sendable {
    private let store: HoldStore
    private let spawner: any CaffeinateSpawning
    private let assertionReader: any AssertionReading
    private let snapshotter: any ProcessSnapshotting
    private let now: @Sendable () -> Date

    public init(
        store: HoldStore,
        spawner: any CaffeinateSpawning,
        assertionReader: any AssertionReading,
        snapshotter: any ProcessSnapshotting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.spawner = spawner
        self.assertionReader = assertionReader
        self.snapshotter = snapshotter
        self.now = now
    }

    public static func standard(paths: TeainatePaths = .standard()) -> TeainateService {
        let snapshotter = PSProcessSnapshotter()
        return TeainateService(
            store: HoldStore(fileURL: paths.stateFile, snapshotter: snapshotter),
            spawner: SystemCaffeinateSpawner(),
            assertionReader: PMSetAssertionReader(),
            snapshotter: snapshotter
        )
    }

    public func on(_ options: HoldOptions) throws -> Hold {
        // Spawn first: a hold record must never describe a process that does not exist.
        let flags = caffeinateFlags(for: options)
        let pid = try spawner.spawn(flags: flags)
        let started = now()
        let hold = Hold(
            id: makeHoldID(),
            kind: options.kind,
            label: options.label,
            source: options.source,
            caffeinatePID: pid,
            flags: flags,
            startedAt: started,
            expiresAt: options.duration.map { started.addingTimeInterval($0) },
            watchedPID: options.watchedPID,
            display: options.display,
            acOnly: options.acOnly
        )
        try store.mutate { $0.append(hold) }
        return hold
    }

    /// Releases one hold by id, or every hold when `id` is nil. Returns what was released.
    public func off(id: String?) throws -> [Hold] {
        let released = try store.mutate { holds -> [Hold] in
            let matching = holds.filter { id == nil || $0.id == id }
            holds.removeAll { hold in matching.contains { $0.id == hold.id } }
            return matching
        }
        for hold in released {
            spawner.terminate(pid: hold.caffeinatePID)
        }
        return released
    }

    public func status() throws -> Status {
        let holds = try store.read()
        let current = now()
        // pmset failing must not hide our own holds.
        let foreign = (try? assertionReader.assertions()) ?? []
        let ours = Set(holds.map(\.caffeinatePID))
        return Status(
            awake: !holds.isEmpty,
            holds: holds.map { hold in
                HoldStatus(
                    id: hold.id, kind: hold.kind, label: hold.label, source: hold.source,
                    expiresAt: hold.expiresAt,
                    remainingSeconds: hold.remainingSeconds(now: current),
                    display: hold.display, acOnly: hold.acOnly
                )
            },
            foreignAssertions: foreign.filter { !ours.contains($0.pid) }
        )
    }

    /// Finds the long-lived `claude` ancestor of this process.
    ///
    /// Claude Code spawns a fresh shell per command, so `$PPID` refers to a process that
    /// exits moments later — pinning to it would release the hold almost immediately.
    public func resolveSessionPID() throws -> pid_t {
        let table = try snapshotter.snapshot()
        guard let pid = findAncestor(of: getpid(), named: ["claude", "claude-code"], in: table) else {
            throw ServiceError.noClaudeAncestor
        }
        return pid
    }
}
