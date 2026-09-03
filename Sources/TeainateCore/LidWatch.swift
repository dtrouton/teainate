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
