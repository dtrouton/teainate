import Testing
import Foundation
@testable import TeainateCore

@Test func parsesMinutesSuffix() throws {
    #expect(try parseDuration("45m") == 2700)
}

@Test func parsesHoursSuffix() throws {
    #expect(try parseDuration("2h") == 7200)
}

@Test func bareNumberMeansMinutes() throws {
    #expect(try parseDuration("90") == 5400)
}

@Test func toleratesWhitespaceAndCase() throws {
    #expect(try parseDuration("  30M  ") == 1800)
}

@Test(arguments: ["", "abc", "-5m", "0", "0m", "5x", "1.5h", "m"])
func rejectsInvalidInput(_ input: String) {
    #expect(throws: DurationParseError.self) { try parseDuration(input) }
}

// The exact input that used to crash `caffeinateFlags`'s `Int(duration)` conversion:
// accepted by `Int(digits)`, but the resulting `TimeInterval` overflowed `Int` when
// converted back downstream. Must now be rejected here instead, with a distinct
// error from a plain format problem.
@Test func rejectsIntMaxAsTooLongRatherThanCrashing() {
    #expect(throws: DurationParseError.tooLong("9223372036854775807")) {
        try parseDuration("9223372036854775807")
    }
}

// 30 days is 43200 minutes; one minute over that must be rejected.
@Test func rejectsJustOverTheMaximum() {
    #expect(throws: DurationParseError.tooLong("43201m")) {
        try parseDuration("43201m")
    }
}

// Exactly the maximum must be accepted — a cap that is off by one at the boundary
// would be its own small bug.
@Test func acceptsExactlyTheMaximum() throws {
    #expect(try parseDuration("43200m") == maxDurationSeconds)
    #expect(try parseDuration("720h") == maxDurationSeconds)
}

// A fix that narrowed already-valid input would be worse than the crash it replaces.
@Test func stillAcceptsOrdinaryDurations() throws {
    #expect(try parseDuration("45m") == 2700)
    #expect(try parseDuration("2h") == 7200)
    #expect(try parseDuration("90") == 5400)
}
