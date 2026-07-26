import Testing
import Foundation
@testable import TeainateCore

private let sample = """
    1     0 launchd
  341     1 powerd
 3279   341 login
 5302  3279 claude
 6707  5302 zsh
 6708  6707 caffeinate
 9001     1 orphaned caffeinate
"""

@Test func parsesPidPpidAndCommand() {
    let table = parsePSOutput(sample)
    #expect(table[6708]?.parentPID == 6707)
    #expect(table[6708]?.command == "caffeinate")
    #expect(table[341]?.command == "powerd")
    #expect(table.count == 7)
}

@Test func commandKeepsOnlyTheFirstField() {
    // `ps -o comm=` can emit a path or trailing words; we want the bare name.
    let table = parsePSOutput(" 9001     1 orphaned caffeinate")
    #expect(table[9001]?.command == "orphaned")
}

@Test func ignoresMalformedLines() {
    let table = parsePSOutput("garbage\n\n  123   456 ok\nnope nope")
    #expect(table.count == 1)
    #expect(table[123]?.command == "ok")
}

@Test func findsClaudeAncestorFromNestedShell() {
    let table = parsePSOutput(sample)
    #expect(findAncestor(of: 6708, named: ["claude"], in: table) == 5302)
}

@Test func returnsNilWhenNoAncestorMatches() {
    let table = parsePSOutput(sample)
    #expect(findAncestor(of: 6708, named: ["nonesuch"], in: table) == nil)
}

@Test func returnsNilForUnknownStartingPID() {
    let table = parsePSOutput(sample)
    #expect(findAncestor(of: 424242, named: ["claude"], in: table) == nil)
}

@Test func terminatesOnParentCycle() {
    // Defensive: a corrupt table must not hang the walk.
    let cyclic = parsePSOutput("  10    11 a\n  11    10 b")
    #expect(findAncestor(of: 10, named: ["claude"], in: cyclic) == nil)
}

@Test func realSnapshotContainsThisProcess() throws {
    let table = try PSProcessSnapshotter().snapshot()
    let me = getpid()
    #expect(table[me] != nil)
}

@Test func parsesArgumentsAsWellAsCommand() {
    let table = parsePSOutput("  6708  6707 caffeinate caffeinate -i -t 300")
    #expect(table[6708]?.command == "caffeinate")
    #expect(table[6708]?.arguments == "caffeinate -i -t 300")
}

@Test func argumentsAreEmptyWhenAbsent() {
    let table = parsePSOutput("  6708  6707 caffeinate")
    #expect(table[6708]?.command == "caffeinate")
    #expect(table[6708]?.arguments == "")
}

@Test func realSnapshotCapturesArgumentsForThisProcess() throws {
    let table = try PSProcessSnapshotter().snapshot()
    let me = try #require(table[getpid()])
    #expect(!me.arguments.isEmpty)
}

@Test func findsClaudeAncestorWhenNameIsAVersionNumber() {
    // Real shape observed on macOS: the Claude Code CLI reports its version as its
    // process name; only the command line identifies it.
    let table = parsePSOutput("""
        25336  5302 zsh /bin/zsh -c source /Users/x/.claude/snapshot
         5302   758 2.1.220 claude
          758   751 zsh -/bin/zsh
        """)
    #expect(findAncestor(of: 25336, named: ["claude"], in: table) == 5302)
}

@Test func findsClaudeAncestorWithExtraArguments() {
    let table = parsePSOutput("""
        25336  5302 zsh /bin/zsh -c source /Users/x/.claude/snapshot
         5302   758 2.1.220 claude --continue
        """)
    #expect(findAncestor(of: 25336, named: ["claude"], in: table) == 5302)
}

@Test func findsClaudeAncestorInvokedByFullPath() {
    let table = parsePSOutput("""
        25336  5302 zsh /bin/zsh -c source /Users/x/.claude/snapshot
         5302   758 2.1.220 /usr/local/bin/claude
        """)
    #expect(findAncestor(of: 25336, named: ["claude"], in: table) == 5302)
}

@Test func identifyingNameFallsBackToCommandWhenArgumentsAreEmpty() {
    let entry = ProcessSnapshot(pid: 1, parentPID: 0, command: "launchd", arguments: "")
    #expect(identifyingName(of: entry) == "launchd")
}

@Test func doesNotMatchOnSubstringWithinArguments() {
    // The word "claude" appears in the args, but the first token's basename is
    // "node" — the match must be on the first token, not a substring search.
    let table = parsePSOutput("""
        25336      1 node node /path/claude-helper.js
        """)
    #expect(findAncestor(of: 25336, named: ["claude"], in: table) == nil)
}
