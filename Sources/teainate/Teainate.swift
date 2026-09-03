import ArgumentParser
import Foundation
import TeainateCore

@main
struct Teainate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teainate",
        abstract: "Keep this Mac awake.",
        version: TeainateVersion.current,
        subcommands: [StatusCommand.self, On.self, Off.self, LidWatch.self],
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

/// Internal. Supervises one lid-closed hold; spawned by TeainateService, never by hand.
struct LidWatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: lidWatchCommandName,
        abstract: "Internal: supervises one lid-closed hold.",
        shouldDisplay: false
    )

    @Option(name: .long) var id: String
    @Option(name: .long) var floor: Int
    @Option(name: .long) var stateFile: String
    // Unconditional: the value always starts with a dash (`-i ...` or `-s ...`), which
    // ArgumentParser's default `.next` strategy refuses to consume as a value — it reads
    // as another option and fails with "Missing value for '--caffeinate'".
    @Option(name: .long, parsing: .unconditional, help: "Space-separated caffeinate flags for the child.")
    var caffeinate: String
    @Option(name: .long) var watchPid: Int32?
    @Flag(name: .long) var acOnly = false
    @Option(name: .long) var label: String?
    @Flag(name: .long, help: "Test hook: never touch the kernel sleep flag. The service never passes this.")
    var noFlag = false

    func run() throws {
        let stateURL = URL(fileURLWithPath: stateFile)
        let logURL = lidWatchLogURL(besideStateFile: stateURL)
        let stop = StopFlag()

        // Ignore at the libc level so the dispatch sources receive the signals.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { stop.set() }
            source.resume()
            return source
        }

        let snapshotter = PSProcessSnapshotter()
        let runner = LidWatchRunner(dependencies: .init(
            store: HoldStore(fileURL: stateURL, snapshotter: snapshotter),
            spawner: SystemCaffeinateSpawner(),
            battery: PMSetBatteryReader(),
            flag: noFlag ? nil : SudoSleepFlagController(),
            liveness: KillZeroLiveness(),
            log: { line in appendLogLine(line, to: logURL) }
        ))
        let config = LidWatchConfig(
            holdID: id, floor: floor, watchedPID: watchPid, acOnly: acOnly,
            caffeinateFlags: caffeinate.split(separator: " ").map(String.init), label: label
        )
        _ = runner.run(config, ownPID: getpid(), stop: stop)
        withExtendedLifetime(sources) {}
    }
}

private func appendLogLine(_ line: String, to url: URL) {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    guard let data = stamped.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
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
