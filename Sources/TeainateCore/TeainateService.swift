import Foundation

public enum ServiceError: Error, Equatable {
    case noClaudeAncestor
    case spawnFailed(String)
    case lidClosedUnavailable
    case lidClosedNotEnabled
    case lidClosedGrantBroken(String)
    case batteryBelowFloor(percent: Int, floor: Int)
    case notOnACPower
    case sleepDisabledElsewhere
    /// The one outcome that leaves the Mac unable to sleep: we set the flag, something
    /// failed, and clearing it failed too. The message carries both errors.
    case sleepFlagStuck(String)
}

public protocol WatcherSpawning: Sendable {
    func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t
}

/// Runs the CLI binary as `lid-watch`. Like caffeinate, the child is left to outlive
/// us; it reparents to launchd and keeps supervising after the CLI exits.
public struct SystemWatcherSpawner: WatcherSpawning {
    public init() {}

    public func spawnWatcher(executable: URL, arguments: [String]) throws -> pid_t {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ServiceError.spawnFailed(error.localizedDescription)
        }
        return process.processIdentifier
    }
}

/// See `TeainateService.classifyOff`.
public enum OffOutcome: Equatable {
    case released([Hold])
    case idNotFound(String)
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
    public let lidClosed: Bool
    public let batteryFloor: Int?

    // Explicit public init: the memberwise one is internal, and the CLI target
    // constructs these from outside the module.
    public init(
        id: String, kind: HoldKind, label: String?, source: HoldSource,
        expiresAt: Date?, remainingSeconds: Int?, display: Bool, acOnly: Bool,
        lidClosed: Bool = false, batteryFloor: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.source = source
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.display = display
        self.acOnly = acOnly
        self.lidClosed = lidClosed
        self.batteryFloor = batteryFloor
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, source, display
        case expiresAt = "expires_at"
        case remainingSeconds = "remaining_seconds"
        case acOnly = "ac_only"
        case lidClosed = "lid_closed"
        case batteryFloor = "battery_floor"
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

public struct LidClosedStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let flagSet: Bool
    /// "teainate", "other", or nil when the flag is not set.
    public let flagSetBy: String?
    public let batteryFloor: Int
    public let lastEnded: EndedHold?
    public let warning: String?

    public init(enabled: Bool, flagSet: Bool, flagSetBy: String?, batteryFloor: Int,
                lastEnded: EndedHold?, warning: String?) {
        self.enabled = enabled; self.flagSet = flagSet; self.flagSetBy = flagSetBy
        self.batteryFloor = batteryFloor; self.lastEnded = lastEnded; self.warning = warning
    }

    enum CodingKeys: String, CodingKey {
        case enabled, warning
        case flagSet = "flag_set"
        case flagSetBy = "flag_set_by"
        case batteryFloor = "battery_floor"
        case lastEnded = "last_ended"
    }

    public static let unavailable = LidClosedStatus(
        enabled: false, flagSet: false, flagSetBy: nil,
        batteryFloor: defaultBatteryFloor, lastEnded: nil, warning: nil)
}

public struct Status: Codable, Sendable, Equatable {
    public let awake: Bool
    public let holds: [HoldStatus]
    public let foreignAssertions: [ForeignAssertion]
    public let untrackedCaffeinate: [UntrackedCaffeinate]
    public let lidClosed: LidClosedStatus

    // Explicit public init: the app target constructs an empty Status as a fallback.
    public init(
        awake: Bool, holds: [HoldStatus], foreignAssertions: [ForeignAssertion],
        untrackedCaffeinate: [UntrackedCaffeinate], lidClosed: LidClosedStatus = .unavailable
    ) {
        self.awake = awake
        self.holds = holds
        self.foreignAssertions = foreignAssertions
        self.untrackedCaffeinate = untrackedCaffeinate
        self.lidClosed = lidClosed
    }

    enum CodingKeys: String, CodingKey {
        case awake, holds
        case foreignAssertions = "foreign_assertions"
        case untrackedCaffeinate = "untracked_caffeinate"
        case lidClosed = "lid_closed"
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public struct LidClosedDependencies: Sendable {
    public let flag: any SleepFlagControlling
    public let grant: any PrivilegeGranting
    public let battery: any BatteryReading
    public let settings: SettingsStore
    public let watcherSpawner: any WatcherSpawning
    public let watcherExecutable: URL
    public let stateFile: URL

    public init(flag: any SleepFlagControlling, grant: any PrivilegeGranting, battery: any BatteryReading,
                settings: SettingsStore, watcherSpawner: any WatcherSpawning,
                watcherExecutable: URL, stateFile: URL) {
        self.flag = flag; self.grant = grant; self.battery = battery; self.settings = settings
        self.watcherSpawner = watcherSpawner; self.watcherExecutable = watcherExecutable
        self.stateFile = stateFile
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
    private let lidClosed: LidClosedDependencies?

    public init(
        store: HoldStore,
        spawner: any CaffeinateSpawning,
        assertionReader: any AssertionReading,
        snapshotter: any ProcessSnapshotting,
        now: @escaping @Sendable () -> Date = { Date() },
        lidClosed: LidClosedDependencies? = nil
    ) {
        self.store = store
        self.spawner = spawner
        self.assertionReader = assertionReader
        self.snapshotter = snapshotter
        self.now = now
        self.lidClosed = lidClosed
    }

    /// `watcherExecutable` is the CLI binary: the app passes its bundled copy, the CLI
    /// passes itself. nil leaves lid-closed holds unavailable.
    public static func standard(
        paths: TeainatePaths = .standard(),
        watcherExecutable: URL? = nil
    ) -> TeainateService {
        let snapshotter = PSProcessSnapshotter()
        return TeainateService(
            store: HoldStore(fileURL: paths.stateFile, snapshotter: snapshotter),
            spawner: SystemCaffeinateSpawner(),
            assertionReader: PMSetAssertionReader(),
            snapshotter: snapshotter,
            lidClosed: watcherExecutable.map { executable in
                LidClosedDependencies(
                    flag: SudoSleepFlagController(), grant: SudoersGrant(),
                    battery: PMSetBatteryReader(),
                    settings: SettingsStore(fileURL: paths.settingsFile),
                    watcherSpawner: SystemWatcherSpawner(),
                    watcherExecutable: executable, stateFile: paths.stateFile)
            }
        )
    }

    public func on(_ options: HoldOptions) throws -> Hold {
        if options.lidClosed { return try onLidClosed(options) }

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

    private func onLidClosed(_ options: HoldOptions) throws -> Hold {
        guard let lid = lidClosed else { throw ServiceError.lidClosedUnavailable }

        // Pre-flight: nothing is touched until every check passes.
        guard lid.grant.isGranted() else { throw ServiceError.lidClosedNotEnabled }
        let floor = lid.settings.read().settings.batteryFloor
        let battery = (try? lid.battery.read()) ?? nil
        if let battery, battery.source == .battery {
            if options.acOnly { throw ServiceError.notOnACPower }
            if let percent = battery.percent, percent <= floor {
                throw ServiceError.batteryBelowFloor(percent: percent, floor: floor)
            }
        }
        try clearOrphanedFlag()
        let state = try store.readState()
        // A live lid-closed hold already owning the flag is why we leave it alone on
        // failure below. A set marker with no live hold instead means a previous
        // attempt here set the flag and got stuck clearing it (see `undo`'s catch) —
        // that is ours to keep retrying, not "someone else", so it must not trip the
        // sleepDisabledElsewhere check.
        let liveLidHold = state.holds.contains(where: \.lidClosed)
        if !liveLidHold, !state.lidFlagOwned, (try? lid.flag.isSet()) == true {
            throw ServiceError.sleepDisabledElsewhere
        }

        do { try lid.flag.set() } catch {
            throw ServiceError.lidClosedGrantBroken("\(error)")
        }

        // From here every failure must put the flag back — unless a live lid-closed
        // hold owned it before we started.
        func undo(_ failure: any Error) -> any Error {
            guard !liveLidHold else { return failure }
            do {
                try lid.flag.clear()
            } catch {
                // Leave the marker set so the next attempt (and `status`) know this
                // stuck flag is ours, not something set outside teainate.
                try? store.mutateState { $0.lidFlagOwned = true }
                return ServiceError.sleepFlagStuck("\(failure); and clearing the sleep flag failed: \(error)")
            }
            return failure
        }

        let flags = caffeinateFlags(for: options)
        let id = makeHoldID()
        let config = LidWatchConfig(
            holdID: id, floor: floor, watchedPID: options.watchedPID, acOnly: options.acOnly,
            caffeinateFlags: flags, label: options.label)
        let pid: pid_t
        do {
            pid = try lid.watcherSpawner.spawnWatcher(
                executable: lid.watcherExecutable,
                arguments: lidWatchArguments(config, stateFile: lid.stateFile))
        } catch {
            throw undo(error)
        }

        let started = now()
        let hold = Hold(
            id: id, kind: options.kind, label: options.label, source: options.source,
            caffeinatePID: pid, flags: flags, startedAt: started,
            expiresAt: options.duration.map { started.addingTimeInterval($0) },
            watchedPID: options.watchedPID, display: options.display, acOnly: options.acOnly,
            lidClosed: true, batteryFloor: floor)
        do {
            try store.mutateState { state in
                state.holds.append(hold)
                state.lidFlagOwned = true
            }
        } catch {
            spawner.terminate(pid: pid)
            throw undo(error)
        }
        return hold
    }

    /// Marker true with no live lid-closed hold means a watcher died without cleaning
    /// up. If the flag is still set, clear it; if clearing fails the marker stays so
    /// `status` keeps warning. If the flag is already clear (a reboot), just drop the marker.
    private func clearOrphanedFlag() throws {
        guard let lid = lidClosed else { return }
        try store.mutateState { state in
            guard state.lidFlagOwned, !state.holds.contains(where: \.lidClosed) else { return }
            let flagSet = (try? lid.flag.isSet()) ?? true
            if !flagSet || (try? lid.flag.clear()) != nil {
                state.lidFlagOwned = false
            }
        }
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
        try clearOrphanedFlag()
        return released
    }

    /// What an `off` call should report to the caller. `--all`'s empty result is a
    /// legitimate no-op — releasing everything over an empty set genuinely succeeded.
    /// `--id` naming a hold that was not released is not: the caller asked for a
    /// specific hold, and if it was a `forever` hold, nothing will ever release it on
    /// its own — no timer, no watched process — so a silent success here can leave the
    /// Mac awake indefinitely.
    public static func classifyOff(id: String?, released: [Hold]) -> OffOutcome {
        if let id, released.isEmpty {
            return .idNotFound(id)
        }
        return .released(released)
    }

    public func status() throws -> Status {
        try clearOrphanedFlag()
        let state = try store.readState()
        let holds = state.holds
        let current = now()
        // pmset failing must not hide our own holds.
        let foreign = (try? assertionReader.assertions()) ?? []
        // A snapshot failure must not hide our own holds either — just leave the
        // untracked list empty rather than throwing status() out entirely.
        let table = (try? snapshotter.snapshot()) ?? [:]
        let ours = ownedPIDs(of: holds, in: table)
        let untracked = table.values
            .filter { $0.command == caffeinateProcessName && !ours.contains($0.pid) }
            .map { UntrackedCaffeinate(pid: $0.pid, arguments: $0.arguments) }
            .sorted { $0.pid < $1.pid }
        return Status(
            awake: !holds.isEmpty,
            holds: holds.map { hold in
                HoldStatus(
                    id: hold.id, kind: hold.kind, label: hold.label, source: hold.source,
                    expiresAt: hold.expiresAt,
                    remainingSeconds: hold.remainingSeconds(now: current),
                    display: hold.display, acOnly: hold.acOnly,
                    lidClosed: hold.lidClosed, batteryFloor: hold.batteryFloor
                )
            },
            foreignAssertions: foreign.filter { !ours.contains($0.pid) },
            untrackedCaffeinate: untracked,
            lidClosed: lidClosedStatus(state)
        )
    }

    private func lidClosedStatus(_ state: StoreState) -> LidClosedStatus {
        guard let lid = lidClosed else { return .unavailable }
        let flagSet = (try? lid.flag.isSet()) ?? false
        let (settings, settingsWarning) = lid.settings.read()
        let liveLid = state.holds.contains(where: \.lidClosed)
        let flagSetBy: String? = flagSet ? (state.lidFlagOwned ? "teainate" : "other") : nil

        var warning = settingsWarning
        if state.lidFlagOwned && !liveLid && flagSet {
            warning = "The sleep-disabled flag is set and teainate cannot clear it. Run: sudo pmset -a disablesleep 0"
        } else if flagSet && !state.lidFlagOwned {
            warning = "Sleep is disabled outside teainate (pmset disablesleep); this Mac will not sleep with the lid closed until that is cleared."
        }
        return LidClosedStatus(
            enabled: lid.grant.isGranted(), flagSet: flagSet, flagSetBy: flagSetBy,
            batteryFloor: settings.batteryFloor, lastEnded: state.lastEnded, warning: warning)
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
        for candidate in candidates where current[candidate.pid]?.command == caffeinateProcessName {
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
