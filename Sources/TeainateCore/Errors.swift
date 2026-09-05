import Foundation

// Every Core error prints as a sentence. ArgumentParser renders an uncaught error as
// `Error: \(error)`, and the app shows `"\(error)"` in alerts, so these descriptions
// are the user-facing text on both surfaces.

extension ServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noClaudeAncestor:
            return "No Claude Code session found in this process tree. Use --for instead, e.g. teainate on --for 45m"
        case .spawnFailed(let message):
            return "Could not start the process: \(message)"
        case .lidClosedUnavailable:
            return "Lid-closed holds are not available in this build."
        case .lidClosedNotEnabled:
            return "Lid-closed holds are not enabled. Enable them from the Teainate menu (Enable lid-closed holds…) first."
        case .lidClosedGrantBroken(let message):
            return "Lid-closed holds are enabled but sudo refused: \(message). Disable and re-enable them from the Teainate menu."
        case .batteryBelowFloor(let percent, let floor):
            return "Battery at \(percent)%, at or below the \(floor)% floor. Plug in, or raise the floor from the Teainate menu."
        case .notOnACPower:
            return "The --ac-only flag with --lid-closed needs the Mac to be plugged in now."
        case .sleepDisabledElsewhere:
            return "Sleep is already disabled outside teainate (pmset disablesleep). An ordinary hold will work with the lid closed until that is cleared."
        case .sleepFlagStuck(let message):
            return "The hold failed and the sleep-disabled flag could not be cleared: \(message). Run: sudo pmset -a disablesleep 0"
        case .durationTooLong:
            return "Durations are limited to \(maxDurationDays) days."
        }
    }
}

extension AssertionReadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pmsetFailed(let status):
            return "Could not read sleep assertions (pmset exited with status \(status))."
        }
    }
}

extension HoldStoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .lockTimeout:
            return "Another teainate process is holding the state file; try again in a moment."
        }
    }
}

extension SleepFlagError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .commandFailed(let status, let message):
            return "Sudo pmset exited with status \(status): \(message)"
        }
    }
}

extension SettingsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .floorOutOfRange(let value):
            return "Battery floor \(value)% is outside \(batteryFloorRange.lowerBound)–\(batteryFloorRange.upperBound)%."
        }
    }
}

extension GrantError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidUsername:
            return "Your macOS username contains characters that cannot be written into a sudoers rule."
        }
    }
}

extension DurationParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalid(let text):
            return "Invalid duration '\(text)'. Use 45m, 2h, or a bare number of minutes."
        case .tooLong(let text):
            return "Duration '\(text)' is longer than the \(maxDurationDays) day maximum."
        }
    }
}

extension ProcessSnapshotError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .psFailed(let status):
            return "Could not read the process table (ps exited with status \(status))."
        }
    }
}
