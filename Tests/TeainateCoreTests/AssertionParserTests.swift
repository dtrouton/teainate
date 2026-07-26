import Testing
import Foundation
@testable import TeainateCore

private func loadFixture() throws -> String {
    let url = try #require(Bundle.module.url(
        forResource: "pmset-assertions", withExtension: "txt", subdirectory: "Fixtures"
    ))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesEveryOwningProcessEntry() throws {
    let parsed = parseAssertions(try loadFixture())
    #expect(parsed.count == 6)
}

@Test func extractsPidProcessAndType() throws {
    let parsed = parseAssertions(try loadFixture())
    let claude = try #require(parsed.first { $0.process == "Claude" })
    #expect(claude.pid == 640)
    #expect(claude.type == "NoIdleSleepAssertion")
}

@Test func keepsBothIdenticallyNamedCaffeinateEntries() throws {
    // The whole design rests on caffeinate assertions being indistinguishable here.
    let parsed = parseAssertions(try loadFixture())
    let caffeinates = parsed.filter { $0.process == "caffeinate" }
    #expect(caffeinates.count == 2)
    #expect(Set(caffeinates.map(\.pid)) == [6667, 6707])
}

@Test func ignoresDetailAndKernelLines() throws {
    let parsed = parseAssertions(try loadFixture())
    #expect(!parsed.contains { $0.process.contains("IOSkywalk") })
    #expect(!parsed.contains { $0.type.hasPrefix("Details") })
}

@Test func returnsEmptyForUnparseableInput() {
    #expect(parseAssertions("totally unexpected output").isEmpty)
}
