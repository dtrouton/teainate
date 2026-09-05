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
        let status = try standardService().status()
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

/// The CLI is its own watcher binary.
func standardService() -> TeainateService {
    TeainateService.standard(
        watcherExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
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

    @Flag(name: .long, help: "Keep the Mac awake even with the lid closed. Needs --for, --session, or --until-pid, and lid-closed holds enabled from the Teainate menu.")
    var lidClosed = false

    func validate() throws {
        let lifetimes = [`for` != nil, session, untilPid != nil].filter { $0 }.count
        if lifetimes > 1 {
            throw ValidationError("Choose at most one of --for, --session, --until-pid.")
        }

        if let text = `for` {
            do {
                _ = try parseDuration(text)
            } catch let error as DurationParseError {
                throw ValidationError("\(error)")
            }
        }

        if lidClosed {
            let duration = try? `for`.map(parseDuration)
            let hasLifetime = `for` != nil || session || untilPid != nil
            if let problem = lidClosedCommandLineProblem(duration: duration ?? nil, hasLifetime: hasLifetime) {
                throw ValidationError(problem)
            }
        }
    }

    func run() throws {
        let service = standardService()

        var watched: pid_t?
        if session {
            // ServiceError.noClaudeAncestor already prints as the sentence the user needs.
            watched = try service.resolveSessionPID()
        } else if let untilPid {
            watched = untilPid
        }

        let options = HoldOptions(
            duration: try `for`.map(parseDuration),
            watchedPID: watched,
            acOnly: acOnly,
            display: display,
            label: label,
            lidClosed: lidClosed,
            source: session ? .claude : .cli
        )
        let hold = try service.on(options)
        let holdStatus = HoldStatus(
            id: hold.id, kind: hold.kind, label: hold.label, source: hold.source,
            expiresAt: hold.expiresAt, remainingSeconds: hold.remainingSeconds(now: Date()),
            display: hold.display, acOnly: hold.acOnly,
            lidClosed: hold.lidClosed, batteryFloor: hold.batteryFloor,
            watchedPID: hold.watchedPID, replaces: hold.replaces
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
        withExtendedLifetime(sources) {
            _ = runner.run(config, ownPID: getpid(), stop: stop)
        }
    }
}

/// Appends one line to the shared watcher log. Several lid-closed holds can run
/// concurrently, each with its own watcher process appending to the same file, so the
/// write must be atomic across processes: `O_APPEND` guarantees the kernel places each
/// write at the file's current end as one operation, which a seek-then-write pair (two
/// separate syscalls) cannot.
private func appendLogLine(_ line: String, to url: URL) {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    guard let data = stamped.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    data.withUnsafeBytes { raw in
        _ = write(fd, raw.baseAddress, raw.count)
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
        if let problem = offSelectionProblem(id: id, all: all, untracked: untracked) {
            throw ValidationError(problem)
        }
    }

    func run() throws {
        let service = standardService()

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
