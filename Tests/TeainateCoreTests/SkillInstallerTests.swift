import Testing
import Foundation
@testable import TeainateCore

private func sandbox() throws -> TeainatePaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-skill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TeainatePaths(
        stateFile: root.appendingPathComponent("holds.json"),
        skillDirectory: root.appendingPathComponent(".claude/skills/teainate"),
        localBinDirectory: root.appendingPathComponent(".local/bin")
    )
}

private func fakeCLI(in paths: TeainatePaths) throws -> URL {
    let url = paths.skillDirectory.deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("teainate")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func reportsNotInstalledOnCleanSystem() throws {
    let paths = try sandbox()
    let installer = SkillInstaller(paths: paths, cliPath: try fakeCLI(in: paths))
    #expect(installer.state() == .notInstalled)
}

@Test func installWritesSkillAndManifest() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)
    try SkillInstaller(paths: paths, cliPath: cli).install()

    let skill = paths.skillDirectory.appendingPathComponent("SKILL.md")
    let manifest = paths.skillDirectory.appendingPathComponent(".teainate-install.json")
    #expect(FileManager.default.fileExists(atPath: skill.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

@Test func installedSkillEmbedsAbsoluteCLIPath() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)
    try SkillInstaller(paths: paths, cliPath: cli).install()

    let contents = try String(
        contentsOf: paths.skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8
    )
    #expect(contents.contains(cli.path))
    #expect(!contents.contains("{{CLI_PATH}}"))
}

@Test func installIsIdempotentAndThenReportsCurrent() throws {
    let paths = try sandbox()
    let installer = SkillInstaller(paths: paths, cliPath: try fakeCLI(in: paths))
    try installer.install()
    try installer.install()
    #expect(installer.state() == .current)
}

@Test func detectsStaleWhenRecordedCLIPathIsGone() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)
    let installer = SkillInstaller(paths: paths, cliPath: cli)
    try installer.install()

    // Simulate the app being moved after install.
    try FileManager.default.removeItem(at: cli)

    guard case .stale = installer.state() else {
        Issue.record("expected stale state after CLI disappeared")
        return
    }
}

@Test func detectsStaleWhenManifestVersionIsOlder() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)
    let installer = SkillInstaller(paths: paths, cliPath: cli)
    try installer.install()

    let manifest = paths.skillDirectory.appendingPathComponent(".teainate-install.json")
    try #"{"cli_path":"\#(cli.path)","version":"0.0.1"}"#
        .write(to: manifest, atomically: true, encoding: .utf8)

    guard case .stale = installer.state() else {
        Issue.record("expected stale state for older version")
        return
    }
}

@Test func missingManifestIsStaleRatherThanNotInstalled() throws {
    let paths = try sandbox()
    let installer = SkillInstaller(paths: paths, cliPath: try fakeCLI(in: paths))
    try installer.install()
    try FileManager.default.removeItem(
        at: paths.skillDirectory.appendingPathComponent(".teainate-install.json")
    )
    guard case .stale = installer.state() else {
        Issue.record("expected stale state when manifest is missing")
        return
    }
}

@Test func installSymlinksLocalBin() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)
    try SkillInstaller(paths: paths, cliPath: cli).install()

    let link = paths.localBinDirectory.appendingPathComponent("teainate")
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    #expect(destination == cli.path)
}

@Test func installLeavesRealFileAtLocalBinUntouched() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)

    try FileManager.default.createDirectory(
        at: paths.localBinDirectory, withIntermediateDirectories: true
    )
    let link = paths.localBinDirectory.appendingPathComponent("teainate")
    let originalContents = "#!/bin/sh\necho not-teainate\n"
    try originalContents.write(to: link, atomically: true, encoding: .utf8)

    try SkillInstaller(paths: paths, cliPath: cli).install()

    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attributes[.type] as? FileAttributeType != .typeSymbolicLink)
    let contents = try String(contentsOf: link, encoding: .utf8)
    #expect(contents == originalContents)

    let skill = paths.skillDirectory.appendingPathComponent("SKILL.md")
    let manifest = paths.skillDirectory.appendingPathComponent(".teainate-install.json")
    #expect(FileManager.default.fileExists(atPath: skill.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

@Test func installReplacesExistingSymlinkAtLocalBin() throws {
    let paths = try sandbox()
    let cli = try fakeCLI(in: paths)

    try FileManager.default.createDirectory(
        at: paths.localBinDirectory, withIntermediateDirectories: true
    )
    let link = paths.localBinDirectory.appendingPathComponent("teainate")
    let staleTarget = paths.localBinDirectory.appendingPathComponent("stale-teainate")
    try "#!/bin/sh\n".write(to: staleTarget, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: staleTarget)

    try SkillInstaller(paths: paths, cliPath: cli).install()

    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    #expect(destination == cli.path)
}

@Test func skillTemplateMentionsKeyCommands() {
    let rendered = renderSkillTemplate(cliPath: "/opt/teainate")
    #expect(rendered.contains("/opt/teainate status --json"))
    #expect(rendered.contains("--session"))
    #expect(rendered.contains("name: teainate"))
}
