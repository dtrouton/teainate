import Testing
@testable import TeainateCore

// Captured from a MacBook (M4, macOS 26.6) — real output, not a guess.
private let onAC = """
Now drawing from 'AC Power'
 -InternalBattery-0 (id=22872163)\t97%; AC attached; not charging present: true
"""
private let onBattery = """
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=22872163)\t83%; discharging; 4:31 remaining present: true
"""
private let charging = """
Now drawing from 'AC Power'
 -InternalBattery-0 (id=22872163)\t45%; charging; 1:20 remaining present: true
"""
private let desktop = "Now drawing from 'AC Power'\n"

@Test func parsesACPower() {
    #expect(parseBatteryOutput(onAC) == BatteryState(source: .ac, percent: 97))
}

@Test func parsesBatteryPower() {
    #expect(parseBatteryOutput(onBattery) == BatteryState(source: .battery, percent: 83))
}

@Test func chargingCountsAsAC() {
    #expect(parseBatteryOutput(charging) == BatteryState(source: .ac, percent: 45))
}

@Test func desktopHasNoPercent() {
    #expect(parseBatteryOutput(desktop) == BatteryState(source: .ac, percent: nil))
}

@Test func garbageIsNil() {
    #expect(parseBatteryOutput("") == nil)
    #expect(parseBatteryOutput("pmset: unrecognized") == nil)
}

@Test func realPmsetBatteryOutputParses() throws {
    // The one test that touches real pmset. Any Mac reports a power source.
    let state = try PMSetBatteryReader().read()
    #expect(state != nil)
}
