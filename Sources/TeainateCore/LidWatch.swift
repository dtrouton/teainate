import Foundation

public let lidWatchCommandName = "lid-watch"

public enum WatcherEndReason: Equatable, Sendable {
    case timerExpired
    case watchedProcessExited
    case unpluggedFromAC
    case batteryAtFloor(percent: Int, floor: Int)
    case released
    case caffeinateFailed(String)

    public var description: String {
        switch self {
        case .timerExpired: return "timer expired"
        case .watchedProcessExited: return "watched process exited"
        case .unpluggedFromAC: return "unplugged from AC power"
        case .batteryAtFloor(let percent, let floor): return "battery \(percent)% at floor \(floor)%"
        case .released: return "released"
        case .caffeinateFailed(let message): return "could not start caffeinate: \(message)"
        }
    }

    /// Reasons that cut work short. Only these are recorded in `last_ended`: a timer
    /// or session ending is the outcome the user asked for, not something to explain.
    public var cutsWorkShort: Bool {
        switch self {
        case .unpluggedFromAC, .batteryAtFloor: return true
        default: return false
        }
    }
}

/// One rail check. nil means keep going. Order matters: a dead child is decisive
/// regardless of power, and an unknown battery is never a reason to stop.
public func watcherDecision(
    childAlive: Bool,
    watchedAlive: Bool?,
    battery: BatteryState?,
    floor: Int,
    acOnly: Bool
) -> WatcherEndReason? {
    if !childAlive { return .timerExpired }
    if watchedAlive == false { return .watchedProcessExited }
    guard let battery, battery.source == .battery else { return nil }
    if acOnly { return .unpluggedFromAC }
    if let percent = battery.percent, percent <= floor {
        return .batteryAtFloor(percent: percent, floor: floor)
    }
    return nil
}

public struct LidWatchConfig: Sendable, Equatable {
    public var holdID: String
    public var floor: Int
    public var watchedPID: pid_t?
    public var acOnly: Bool
    /// The flags the watcher's caffeinate child gets, before `-w <watcher pid>` is added.
    public var caffeinateFlags: [String]
    public var label: String?

    public init(holdID: String, floor: Int, watchedPID: pid_t?, acOnly: Bool,
                caffeinateFlags: [String], label: String?) {
        self.holdID = holdID
        self.floor = floor
        self.watchedPID = watchedPID
        self.acOnly = acOnly
        self.caffeinateFlags = caffeinateFlags
        self.label = label
    }
}

/// Command line for `teainate lid-watch`. Caffeinate flags travel as one space-joined
/// option value so ArgumentParser never has to see `-i` as a flag of its own.
public func lidWatchArguments(_ config: LidWatchConfig, stateFile: URL) -> [String] {
    var args = [
        lidWatchCommandName,
        "--id", config.holdID,
        "--floor", String(config.floor),
        "--state-file", stateFile.path,
        "--caffeinate", config.caffeinateFlags.joined(separator: " "),
    ]
    if let pid = config.watchedPID { args += ["--watch-pid", String(pid)] }
    if config.acOnly { args.append("--ac-only") }
    if let label = config.label { args += ["--label", label] }
    return args
}

/// Ties the child to the watcher: if the watcher dies for any reason, SIGKILL
/// included, caffeinate releases on its own. This path can never orphan a caffeinate.
public func watcherChildFlags(caffeinateFlags: [String], watcherPID: pid_t) -> [String] {
    caffeinateFlags + ["-w", String(watcherPID)]
}

public protocol ProcessLiveness: Sendable {
    func isAlive(_ pid: pid_t) -> Bool
}

/// `kill(pid, 0)` liveness. Reaps first so an exited child of ours is not mistaken
/// for a live zombie; after Foundation has already reaped it, waitpid fails and
/// kill reports ESRCH, both of which read as "gone".
public struct KillZeroLiveness: ProcessLiveness {
    public init() {}
    public func isAlive(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Set from a signal handler's dispatch source; read by the loop.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func set() { lock.lock(); flag = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Supervises one lid-closed hold. Runs inside `teainate lid-watch`.
public struct LidWatchRunner: Sendable {
    public struct Dependencies: Sendable {
        public var store: HoldStore
        public var spawner: any CaffeinateSpawning
        public var battery: any BatteryReading
        /// nil = never touch the kernel flag (the `--no-flag` test hook).
        public var flag: (any SleepFlagControlling)?
        public var liveness: any ProcessLiveness
        public var log: @Sendable (String) -> Void
        public var sleep: @Sendable (UInt32) -> Void
        public var now: @Sendable () -> Date
        /// Seconds between rail checks. Stop requests are noticed every second.
        public var checkInterval: UInt32

        public init(
            store: HoldStore, spawner: any CaffeinateSpawning, battery: any BatteryReading,
            flag: (any SleepFlagControlling)?, liveness: any ProcessLiveness,
            log: @escaping @Sendable (String) -> Void,
            sleep: @escaping @Sendable (UInt32) -> Void = { _ = Darwin.sleep($0) },
            now: @escaping @Sendable () -> Date = { Date() },
            checkInterval: UInt32 = 30
        ) {
            self.store = store; self.spawner = spawner; self.battery = battery
            self.flag = flag; self.liveness = liveness; self.log = log
            self.sleep = sleep; self.now = now; self.checkInterval = checkInterval
        }
    }

    private let deps: Dependencies

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    public func run(_ config: LidWatchConfig, ownPID: pid_t, stop: StopFlag) -> WatcherEndReason {
        // The service already set the flag before spawning us. Setting it again is
        // idempotent and closes the window where a previous watcher's exit cleared it
        // between the service's set and its record.
        if let flag = deps.flag {
            do { try flag.set() } catch { deps.log("\(config.holdID) could not re-set sleep flag: \(error)") }
        }

        let child: pid_t
        do {
            child = try deps.spawner.spawn(flags: watcherChildFlags(
                caffeinateFlags: config.caffeinateFlags, watcherPID: ownPID))
        } catch {
            let reason = WatcherEndReason.caffeinateFailed("\(error)")
            finish(config, reason: reason)
            return reason
        }

        var reason: WatcherEndReason?
        while reason == nil {
            var waited: UInt32 = 0
            while waited < deps.checkInterval && !stop.isSet {
                deps.sleep(1)
                waited += 1
            }
            if stop.isSet { reason = .released; break }

            let battery = (try? deps.battery.read()) ?? nil
            reason = watcherDecision(
                childAlive: deps.liveness.isAlive(child),
                watchedAlive: config.watchedPID.map(deps.liveness.isAlive),
                battery: battery, floor: config.floor, acOnly: config.acOnly
            )
        }

        deps.spawner.terminate(pid: child)
        finish(config, reason: reason ?? .released)
        return reason ?? .released
    }

    /// Two separate mutations on purpose: removing the record and noting the reason
    /// must land even when clearing the flag fails.
    private func finish(_ config: LidWatchConfig, reason: WatcherEndReason) {
        do {
            try deps.store.mutateState { state in
                state.holds.removeAll { $0.id == config.holdID }
                if reason.cutsWorkShort {
                    state.lastEnded = EndedHold(
                        id: config.holdID, label: config.label,
                        reason: reason.description, at: deps.now())
                }
            }
        } catch {
            deps.log("\(config.holdID) could not update state: \(error)")
        }

        if let flag = deps.flag {
            do {
                try deps.store.mutateState { state in
                    guard !state.holds.contains(where: \.lidClosed) else { return }
                    try flag.clear()
                    state.lidFlagOwned = false
                }
            } catch {
                deps.log("\(config.holdID) could not clear sleep flag: \(error)")
            }
        }
        deps.log("\(config.holdID) ended: \(reason.description)")
    }
}
