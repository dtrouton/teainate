import Foundation

public enum DurationParseError: Error, Equatable {
    case invalid(String)
    case tooLong(String)
}

/// The longest duration `--for` will accept. Generous enough for any real hold, and
/// finite so a mistyped huge number (or `Int.max`) fails here with a clear message
/// rather than overflowing `Int` later when the duration becomes a caffeinate `-t`
/// flag (`String(Int(duration))` in `caffeinateFlags`).
public let maxDurationDays: Int = 30
public let maxDurationSeconds: TimeInterval = TimeInterval(maxDurationDays) * 24 * 60 * 60

/// Parses a human duration into seconds.
/// Accepts `45m`, `2h`, or a bare number meaning minutes. Must be a positive whole
/// number no longer than `maxDurationDays`.
public func parseDuration(_ text: String) throws -> TimeInterval {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { throw DurationParseError.invalid(text) }

    let multiplier: TimeInterval
    let digits: Substring

    switch trimmed.last {
    case "m":
        multiplier = 60
        digits = trimmed.dropLast()
    case "h":
        multiplier = 3600
        digits = trimmed.dropLast()
    default:
        multiplier = 60
        digits = Substring(trimmed)
    }

    guard !digits.isEmpty,
          digits.allSatisfy(\.isNumber),
          let value = Int(digits),
          value > 0
    else { throw DurationParseError.invalid(text) }

    // `Int` -> `Double` cannot trap (it only loses precision at extreme magnitudes),
    // so this is safe even when `value` is `Int.max`. It is the *result* of this
    // multiplication that must be bounded before anything downstream converts it
    // back to `Int`.
    let seconds = TimeInterval(value) * multiplier
    guard seconds <= maxDurationSeconds else { throw DurationParseError.tooLong(text) }
    return seconds
}
