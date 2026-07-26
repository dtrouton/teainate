import Foundation

public enum DurationParseError: Error, Equatable {
    case invalid(String)
}

/// Parses a human duration into seconds.
/// Accepts `45m`, `2h`, or a bare number meaning minutes. Must be a positive whole number.
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

    return TimeInterval(value) * multiplier
}
