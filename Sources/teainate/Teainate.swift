import ArgumentParser
import Foundation
import TeainateCore

@main
struct Teainate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teainate",
        abstract: "Keep this Mac awake.",
        version: TeainateVersion.current,
        subcommands: [StatusCommand.self, On.self, Off.self],
        defaultSubcommand: StatusCommand.self
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show what is keeping this Mac awake."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let status = try TeainateService.standard().status()
        if json {
            let data = try TeainateCore.Status.encoder.encode(status)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(renderStatus(status))
        }
    }
}

/// Renders as `Error: <description>` on stderr with a non-zero exit status —
/// unlike CleanExit, which prints to stdout and exits 0.
struct FriendlyError: Error, CustomStringConvertible {
    let description: String
}

struct On: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start holding this Mac awake."
    )

    @Option(name: .customLong("for"), help: "How long to hold: 45m, 2h, or a bare number of minutes.")
    var `for`: String?

    @Flag(name: .long, help: "Hold until the enclosing Claude Code session exits.")
    var session = false

    @Option(name: .long, help: "Hold until this process id exits.")
    var untilPid: Int32?

    @Flag(name: .long, help: "Release the hold when unplugged from AC power.")
    var acOnly = false

    @Flag(name: .long, help: "Also keep the display awake.")
    var display = false

    @Option(name: .long, help: "A human-readable note shown in the menu bar.")
    var label: String?

    func validate() throws {
        let lifetimes = [`for` != nil, session, untilPid != nil].filter { $0 }.count
        if lifetimes > 1 {
            throw ValidationError("Choose at most one of --for, --session, --until-pid.")
        }

        if let text = `for` {
            do {
                _ = try parseDuration(text)
            } catch DurationParseError.tooLong {
                throw ValidationError(
                    "Duration '\(text)' is longer than the \(maxDurationDays) day maximum."
                )
            } catch {
                throw ValidationError(
                    "Invalid duration '\(text)'. Use 45m, 2h, or a bare number of minutes."
                )
            }
        }
    }

    func run() throws {
        let service = TeainateService.standard()

        var watched: pid_t?
        if session {
            do {
                watched = try service.resolveSessionPID()
            } catch ServiceError.noClaudeAncestor {
                throw FriendlyError(
                    description: "No Claude Code session found in this process tree. Use --for instead, e.g. teainate on --for 45m"
                )
            }
        } else if let untilPid {
            watched = untilPid
        }

        let options = HoldOptions(
            duration: try `for`.map(parseDuration),
            watchedPID: watched,
            acOnly: acOnly,
            display: display,
            label: label,
            source: session ? .claude : .cli
        )
        let hold = try service.on(options)
        let holdStatus = HoldStatus(
            id: hold.id, kind: hold.kind, label: hold.label, source: hold.source,
            expiresAt: hold.expiresAt, remainingSeconds: hold.remainingSeconds(now: Date()),
            display: hold.display, acOnly: hold.acOnly
        )
        print("● Holding the Mac awake — \(describe(holdStatus))")
    }
}

struct Off: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Release holds."
    )

    @Option(name: .long, help: "Release only this hold id.")
    var id: String?

    @Flag(name: .long, help: "Release every teainate hold.")
    var all = false

    @Flag(name: .long, help: "Terminate caffeinate processes teainate did not start.")
    var untracked = false

    func validate() throws {
        if id == nil && !all && !untracked {
            throw ValidationError("Specify --id <id>, --all, or --untracked.")
        }
    }

    func run() throws {
        let service = TeainateService.standard()

        // Deliberately separate from --all: this kills processes we did not start
        // and cannot prove are stale, so it must always be asked for explicitly.
        if untracked {
            let reclaimed = try service.reclaimUntracked()
            if reclaimed.isEmpty {
                print("No untracked caffeinate processes.")
            } else {
                for process in reclaimed {
                    print("Terminated pid \(process.pid) — \(process.arguments)")
                }
            }
            if id == nil && !all { return }
        }

        let released = try service.off(id: id)
        switch TeainateService.classifyOff(id: id, released: released) {
        case .idNotFound(let id):
            throw FriendlyError(description: "No hold with id '\(id)'.")
        case .released(let released):
            if released.isEmpty {
                print("No matching holds.")
            } else {
                print("Released \(released.count) hold\(released.count == 1 ? "" : "s").")
            }
        }
    }
}
