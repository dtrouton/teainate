import Testing
@testable import TeainateCore

@Test func sleepDisabledOneIsSet() {
    let out = " System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1\n"
    #expect(parseSleepDisabled(out) == true)
}

@Test func sleepDisabledZeroIsNotSet() {
    #expect(parseSleepDisabled(" SleepDisabled        0\n") == false)
}

@Test func missingSleepDisabledIsNotSet() {
    #expect(parseSleepDisabled(" sleep 1\n hibernatemode 3\n") == false)
}

@Test func realPmsetGlobalOutputParsesWithoutPrivilege() throws {
    // Reading is unprivileged; this must never prompt. Its value is unknown here.
    _ = try SudoSleepFlagController().isSet()
}
