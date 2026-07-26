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

public struct UntrackedCaffeinate: Codable, Sendable, Equatable {
    public let pid: pid_t
    public let arguments: String

    public init(pid: pid_t, arguments: String) {
        self.pid = pid
        self.arguments = arguments
    }
}

public struct Status: Codable, Sendable, Equatable {
    public let awake: Bool
    public let holds: [HoldStatus]
    public let foreignAssertions: [ForeignAssertion]
    public let untrackedCaffeinate: [UntrackedCaffeinate]

    // Explicit public init: the app target constructs an empty Status as a fallback.
    public init(
        awake: Bool, holds: [HoldStatus], foreignAssertions: [ForeignAssertion],
        untrackedCaffeinate: [UntrackedCaffeinate]
    ) {
        self.awake = awake
        self.holds = holds
        self.foreignAssertions = foreignAssertions
        self.untrackedCaffeinate = untrackedCaffeinate
    }

    enum CodingKeys: String, CodingKey {
        case awake, holds
        case foreignAssertions = "foreign_assertions"
        case untrackedCaffeinate = "untracked_caffeinate"
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
        do {
            try store.mutate { $0.append(hold) }
        } catch {
            // Never leave an untracked process holding the Mac awake.
            spawner.terminate(pid: pid)
            throw error
        }
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
        // A snapshot failure must not hide our own holds either — just leave the
        // untracked list empty rather than throwing status() out entirely.
        let table = (try? snapshotter.snapshot()) ?? [:]
        let untracked = table.values
            .filter { $0.command == "caffeinate" && !ours.contains($0.pid) }
            .map { UntrackedCaffeinate(pid: $0.pid, arguments: $0.arguments) }
            .sorted { $0.pid < $1.pid }
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
            foreignAssertions: foreign.filter { !ours.contains($0.pid) },
            untrackedCaffeinate: untracked
        )
    }

    /// Terminates caffeinate processes teainate did not start.
    ///
    /// We cannot prove such a process is a leaked hold of ours rather than another
    /// tool's — every caffeinate assertion is anonymous. This is therefore never
    /// invoked by `off(id: nil)`; the caller must ask for it explicitly.
    public func reclaimUntracked() throws -> [UntrackedCaffeinate] {
        let candidates = try status().untrackedCaffeinate

        // Re-verify against a fresh snapshot immediately before signalling: a PID
        // that exited between the two reads could have been recycled by an
        // unrelated process, and this is the one path that terminates processes
        // teainate did not start. This narrows the race window rather than closing
        // it — a PID could in principle still be recycled between this re-check
        // and the `kill` itself.
        let current = (try? snapshotter.snapshot()) ?? [:]
        var reclaimed: [UntrackedCaffeinate] = []
        for candidate in candidates where current[candidate.pid]?.command == "caffeinate" {
            spawner.terminate(pid: candidate.pid)
            reclaimed.append(candidate)
        }
        return reclaimed
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
