import Foundation

public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let command: String
    /// Full command line, used to identify what kind of hold an untracked
    /// caffeinate process represents. `pmset` cannot supply this.
    public let arguments: String

    public init(pid: pid_t, parentPID: pid_t, command: String, arguments: String = "") {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
        self.arguments = arguments
    }
}

public protocol ProcessSnapshotting: Sendable {
    func snapshot() throws -> [pid_t: ProcessSnapshot]
}

public enum ProcessSnapshotError: Error, Equatable {
    case psFailed(status: Int32)
}

/// Parses `ps -eo pid=,ppid=,ucomm=,args=` output. Malformed lines are skipped rather than
/// fatal — a single odd line must never blind us to the rest of the process table.
///
/// `ucomm` (not `comm`) is deliberate: `comm` reports the executable's path — for a
/// process exec'd by absolute path (as `SystemCaffeinateSpawner` does), that's a
/// truncated `/usr/bin/caffein` rather than `caffeinate`, which silently breaks every
/// `command == "caffeinate"` comparison in this codebase. `ucomm` is the bare
/// accounting name and does not have this problem.
///
/// Known limitation: `ucomm` can contain spaces for some processes (e.g. a helper
/// named "Foo Helper"), and this whitespace-splitting parser will split such a name
/// at its first space, putting only the first word in `command`. This is harmless
/// here because the only names ever matched against (`caffeinate`, `claude`,
/// `claude-code`) contain no spaces — but this parser is not a correct `ucomm` parser
/// in general.
public func parsePSOutput(_ text: String) -> [pid_t: ProcessSnapshot] {
    var table: [pid_t: ProcessSnapshot] = [:]
    for line in text.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3,
              let pid = pid_t(fields[0]),
              let ppid = pid_t(fields[1])
        else { continue }
        table[pid] = ProcessSnapshot(
            pid: pid, parentPID: ppid, command: String(fields[2]),
            arguments: fields.dropFirst(3).joined(separator: " ")
        )
    }
    return table
}

/// Walks up the process tree looking for a named ancestor.
/// Bounded so a corrupt or cyclic table cannot hang the caller.
public func findAncestor(
    of pid: pid_t,
    named names: Set<String>,
    in table: [pid_t: ProcessSnapshot]
) -> pid_t? {
    var current = pid
    var seen: Set<pid_t> = []
    while let entry = table[current], !seen.contains(current) {
        seen.insert(current)
        if names.contains(entry.command) { return entry.pid }
        if entry.parentPID <= 1 { return nil }
        current = entry.parentPID
    }
    return nil
}

public struct PSProcessSnapshotter: ProcessSnapshotting {
    public init() {}

    public func snapshot() throws -> [pid_t: ProcessSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,ucomm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessSnapshotError.psFailed(status: process.terminationStatus)
        }
        return parsePSOutput(String(decoding: data, as: UTF8.self))
    }
}
