import Testing
import Foundation
@testable import TeainateCore

/// A description is user-facing if it reads as a sentence: it has a space and is not
/// the bare Swift case name.
private func isSentence(_ error: any Error) -> Bool {
    let text = "\(error)"
    return text.contains(" ") && !text.hasPrefix(".") && text.first?.isUppercase == true
}

@Test func serviceErrorsReadAsSentences() {
    let cases: [ServiceError] = [
        .noClaudeAncestor, .spawnFailed("boom"), .lidClosedUnavailable, .lidClosedNotEnabled,
        .lidClosedGrantBroken("sudo: a password is required"),
        .batteryBelowFloor(percent: 12, floor: 15), .notOnACPower, .sleepDisabledElsewhere,
        .sleepFlagStuck("x"), .durationTooLong,
    ]
    for error in cases { #expect(isSentence(error), "\(error)") }
    #expect("\(ServiceError.batteryBelowFloor(percent: 12, floor: 15))".contains("12%"))
    #expect("\(ServiceError.sleepFlagStuck("x"))".contains("sudo pmset -a disablesleep 0"))
}

@Test func storeFlagSettingsGrantDurationSnapshotErrorsReadAsSentences() {
    let all: [any Error] = [
        HoldStoreError.lockTimeout,
        SleepFlagError.commandFailed(status: 1, message: "denied"),
        SettingsError.floorOutOfRange(51),
        GrantError.invalidUsername,
        DurationParseError.invalid("5x"), DurationParseError.tooLong("99d"),
        ProcessSnapshotError.psFailed(status: 1),
    ]
    for error in all { #expect(isSentence(error), "\(error)") }
    #expect("\(HoldStoreError.lockTimeout)".contains("try again"))
}

@Test func sudoFailureNamesTheCommandNaturally() {
    #expect("\(SleepFlagError.commandFailed(status: 1, message: "denied"))".hasPrefix("The sudo pmset command exited"))
}
