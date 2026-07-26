import Foundation

public enum SkillInstallState: Sendable, Equatable {
    case notInstalled
    case current
    case stale(String)
}

private struct InstallManifest: Codable {
    let cliPath: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case cliPath = "cli_path"
        case version
    }
}

public func renderSkillTemplate(cliPath: String) -> String {
    skillTemplate.replacingOccurrences(of: "{{CLI_PATH}}", with: cliPath)
}

public struct SkillInstaller: Sendable {
    private let paths: TeainatePaths
    private let cliPath: URL

    public init(paths: TeainatePaths, cliPath: URL) {
        self.paths = paths
        self.cliPath = cliPath
    }

    private var skillFile: URL { paths.skillDirectory.appendingPathComponent("SKILL.md") }
    private var manifestFile: URL {
        paths.skillDirectory.appendingPathComponent(".teainate-install.json")
    }

    public func state() -> SkillInstallState {
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            return .notInstalled
        }
        guard let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(InstallManifest.self, from: data)
        else {
            return .stale("install manifest missing")
        }
        guard FileManager.default.fileExists(atPath: manifest.cliPath) else {
            return .stale("recorded teainate path no longer exists")
        }
        guard manifest.version == TeainateVersion.current else {
            return .stale(
                "installed for teainate \(manifest.version), now running \(TeainateVersion.current)"
            )
        }
        return .current
    }

    public func install() throws {
        try FileManager.default.createDirectory(
            at: paths.skillDirectory, withIntermediateDirectories: true
        )
        try renderSkillTemplate(cliPath: cliPath.path)
            .write(to: skillFile, atomically: true, encoding: .utf8)

        let manifest = InstallManifest(cliPath: cliPath.path, version: TeainateVersion.current)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestFile, options: .atomic)

        try? installSymlink()
    }

    /// Convenience only — the skill works without it because SKILL.md carries an
    /// absolute path. Deliberately refuses to replace anything that is not already
    /// a symlink: this is the one path teainate touches outside its own directories,
    /// and a best-effort convenience must never destroy a file the user put there.
    private func installSymlink() throws {
        try FileManager.default.createDirectory(
            at: paths.localBinDirectory, withIntermediateDirectories: true
        )
        let link = paths.localBinDirectory.appendingPathComponent("teainate")

        let attributes = try? FileManager.default.attributesOfItem(atPath: link.path)
        if let type = attributes?[.type] as? FileAttributeType {
            guard type == .typeSymbolicLink else { return }   // not ours — leave it alone
            try FileManager.default.removeItem(at: link)
        }

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cliPath)
    }
}

private let skillTemplate = """
---
name: teainate
description: >-
  Use when the user wants to keep this Mac awake or stop it sleeping, asks why the Mac
  will not sleep, or is about to start a long-running build, migration, test suite, or
  download that must not be interrupted by sleep. Also use to inspect or release
  existing sleep holds.
---

# teainate

Controls macOS sleep prevention. The `teainate` CLI wraps `caffeinate` and shares state
with the teainate menu bar app, so anything you do here is visible in the menu bar.

Binary: `{{CLI_PATH}}`

## Before a long-running task

Take a session-scoped hold so the Mac stays awake until this Claude Code session ends:

```bash
{{CLI_PATH}} on --session --label "running test suite"
```

This auto-releases when the session exits, including on crash. Prefer it over a timed
hold — it cannot leak, and it needs no renewal.

If no Claude Code session is found in the process tree, the command fails with a
non-zero exit status and says so on stderr. Fall back to a timer:

```bash
{{CLI_PATH}} on --for 45m --label "running test suite"
```

Because it exits non-zero on failure, it is safe to chain: `teainate on --session &&
long_running_job` will not run the job if the hold could not be taken.

## Checking state

```bash
{{CLI_PATH}} status --json
```

Returns `awake`, the list of `holds` teainate owns, `foreign_assertions` (other
processes holding the Mac awake, from `pmset`), and `untracked_caffeinate`
(`caffeinate` processes teainate did not start, with their command lines).

When the user asks "why won't my Mac sleep?", check `foreign_assertions` first — the
answer is often another app, not teainate. `untracked_caffeinate` carries each
process's actual flags, which `pmset` cannot report, so it is the better place to
look when the culprit is a stray `caffeinate`.

## Options

- `--for 45m` / `--for 2h` / `--for 90` (bare number means minutes)
- `--session` — hold until this Claude Code session exits
- `--until-pid <pid>` — hold until that process exits
- `--ac-only` — release automatically when unplugged from AC power
- `--display` — also keep the screen on (off by default; most tasks do not need it)
- `--label "..."` — a note shown in the menu bar

## Releasing

```bash
{{CLI_PATH}} off --id h_3f2a   # one hold
{{CLI_PATH}} off --all         # every teainate hold
```

Release holds you took once the work finishes. Do not release holds you did not create
without asking the user — they may have set them from the menu bar.

`--untracked` terminates `caffeinate` processes teainate did not start. Never run it
without the user explicitly asking: those processes may belong to another tool, or to
another Claude Code session that is still working. `off --all` deliberately does not
touch them.
"""
