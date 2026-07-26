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
