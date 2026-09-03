import Testing
import Foundation
@testable import TeainateCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-sudoers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func ruleIsExactlyTheTwoLiteralCommands() {
    let grant = SudoersGrant(username: "denver", directory: URL(fileURLWithPath: "/etc/sudoers.d"))
    #expect(grant.rule ==
        "denver ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    #expect(grant.fileURL.path == "/etc/sudoers.d/teainate-denver")
}

@Test func fileNameNeverContainsADot() {
    // sudo silently ignores sudoers.d files whose names contain '.'.
    let grant = SudoersGrant(username: "first.last", directory: URL(fileURLWithPath: "/etc/sudoers.d"))
    #expect(grant.fileURL.lastPathComponent == "teainate-first_last")
}

@Test func notGrantedWhenFileMissing() throws {
    #expect(SudoersGrant(username: "u", directory: try tempDir()).isGranted() == false)
}

@Test func grantedWhenFileHoldsExactlyTheRule() throws {
    let grant = SudoersGrant(username: "u", directory: try tempDir())
    try (grant.rule + "\n").write(to: grant.fileURL, atomically: true, encoding: .utf8)
    #expect(grant.isGranted() == true)
}

@Test func notGrantedWhenFileHoldsSomethingElse() throws {
    let grant = SudoersGrant(username: "u", directory: try tempDir())
    try "u ALL=(ALL) NOPASSWD: ALL\n".write(to: grant.fileURL, atomically: true, encoding: .utf8)
    #expect(grant.isGranted() == false)
}

@Test func installScriptValidatesWithVisudoBeforeMoving() throws {
    let script = try SudoersGrant(username: "u", directory: try tempDir()).installScript()
    #expect(script.contains("/usr/sbin/visudo -c -f"))
    #expect(script.contains("chmod 0440"))
    #expect(script.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1"))
}

@Test func unsafeUsernameIsRefused() throws {
    let grant = SudoersGrant(username: "bad user; rm -rf /", directory: try tempDir())
    #expect(throws: GrantError.invalidUsername) { try grant.installScript() }
}
