import Testing
import Foundation
@testable import TeainateCore

private func decide(
    child: Bool = true, watched: Bool? = nil,
    battery: BatteryState? = BatteryState(source: .ac, percent: 80),
    floor: Int = 15, acOnly: Bool = false
) -> WatcherEndReason? {
    watcherDecision(childAlive: child, watchedAlive: watched, battery: battery, floor: floor, acOnly: acOnly)
}

@Test func continuesWhenEverythingIsFine() {
    #expect(decide() == nil)
}

@Test func endsWhenCaffeinateChildIsGone() {
    #expect(decide(child: false) == .timerExpired)
}

@Test func endsWhenWatchedProcessIsGone() {
    #expect(decide(watched: false) == .watchedProcessExited)
}

// 14 and 16, never 15: floor-minus-one must end, floor-plus-one must continue.
@Test func endsAtOrBelowFloorOnBattery() {
    #expect(decide(battery: BatteryState(source: .battery, percent: 14)) == .batteryAtFloor(percent: 14, floor: 15))
    #expect(decide(battery: BatteryState(source: .battery, percent: 15)) == .batteryAtFloor(percent: 15, floor: 15))
    #expect(decide(battery: BatteryState(source: .battery, percent: 16)) == nil)
}

@Test func floorDoesNotApplyOnAC() {
    #expect(decide(battery: BatteryState(source: .ac, percent: 3)) == nil)
}

@Test func acOnlyEndsOnBatteryRegardlessOfPercent() {
    #expect(decide(battery: BatteryState(source: .battery, percent: 99), acOnly: true) == .unpluggedFromAC)
}

@Test func unknownBatteryContinues() {
    #expect(decide(battery: nil) == nil)
    #expect(decide(battery: BatteryState(source: .battery, percent: nil)) == nil)
}

@Test func childDeathWinsOverEverythingElse() {
    #expect(decide(child: false, watched: false, battery: BatteryState(source: .battery, percent: 1)) == .timerExpired)
}

@Test func onlyPowerReasonsCutWorkShort() {
    #expect(WatcherEndReason.batteryAtFloor(percent: 14, floor: 15).cutsWorkShort)
    #expect(WatcherEndReason.unpluggedFromAC.cutsWorkShort)
    #expect(!WatcherEndReason.timerExpired.cutsWorkShort)
    #expect(!WatcherEndReason.watchedProcessExited.cutsWorkShort)
    #expect(!WatcherEndReason.released.cutsWorkShort)
}

@Test func argumentsAreDeterministic() {
    let config = LidWatchConfig(holdID: "h_1", floor: 20, watchedPID: 6707, acOnly: true,
                                caffeinateFlags: ["-i", "-t", "600"], label: "build")
    let args = lidWatchArguments(config, stateFile: URL(fileURLWithPath: "/tmp/s/holds.json"))
    #expect(args == ["lid-watch", "--id", "h_1", "--floor", "20", "--state-file", "/tmp/s/holds.json",
                     "--caffeinate", "-i -t 600", "--watch-pid", "6707", "--ac-only", "--label", "build"])
}

@Test func childFlagsAppendTheWatcherPID() {
    #expect(watcherChildFlags(caffeinateFlags: ["-i", "-t", "600"], watcherPID: 4242) == ["-i", "-t", "600", "-w", "4242"])
}

@Test func commandLineLidClosedNeedsALifetime() {
    #expect(lidClosedCommandLineProblem(duration: nil, hasLifetime: false) != nil)
    #expect(lidClosedCommandLineProblem(duration: nil, hasLifetime: true) == nil)
}

@Test func commandLineLidClosedCapsAtEightHours() {
    #expect(lidClosedCommandLineProblem(duration: 8 * 3600, hasLifetime: true) == nil)
    #expect(lidClosedCommandLineProblem(duration: 8 * 3600 + 1, hasLifetime: true) != nil)
}
