import Testing
import Foundation
@testable import TeainateCore

@Test func readsOwnStartTime() {
    let reader = ProcPIDInfoStartTimeReader()
    let mine = reader.startTime(of: getpid())
    #expect(mine != nil)
    // Started after 2020 and not in the future.
    #expect((mine?.seconds ?? 0) > 1_577_836_800)
    #expect(Double(mine?.seconds ?? .max) <= Date().timeIntervalSince1970)
    #expect((0..<1_000_000).contains(Int(mine?.microseconds ?? -1)))
}

@Test func missingProcessHasNoStartTime() {
    #expect(ProcPIDInfoStartTimeReader().startTime(of: 999_999) == nil)
}

@Test func startTimeIsStable() {
    let reader = ProcPIDInfoStartTimeReader()
    #expect(reader.startTime(of: getpid()) == reader.startTime(of: getpid()))
}

@Test func startTimeRoundTripsThroughJSONExactly() throws {
    let time = ProcessStartTime(seconds: 1_757_000_000, microseconds: 123_456)
    let data = try Hold.encoder.encode(time)
    #expect(try Hold.decoder.decode(ProcessStartTime.self, from: data) == time)
}
