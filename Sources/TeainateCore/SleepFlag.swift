import Foundation

public enum SleepFlagError: Error, Equatable {
    case commandFailed(status: Int32, message: String)
}

/// The kernel's SleepDisabled flag (`pmset -a disablesleep`). Setting and clearing
/// need root and go through the literal sudoers grant; reading does not.
public protocol SleepFlagControlling: Sendable {
    func set() throws
    func clear() throws
    func isSet() throws -> Bool
}

/// Parses `pmset -g`. The line is ` SleepDisabled<whitespace>1` when set; absent or 0 otherwise.
public func parseSleepDisabled(_ text: String) -> Bool {
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, fields[0] == "SleepDisabled" {
            return fields[1] == "1"
        }
    }
    return false
}

public struct SudoSleepFlagController: SleepFlagControlling {
    public init() {}

    public func set() throws { try sudo(["/usr/bin/pmset", "-a", "disablesleep", "1"]) }
    public func clear() throws { try sudo(["/usr/bin/pmset", "-a", "disablesleep", "0"]) }

    public func isSet() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseSleepDisabled(String(decoding: data, as: UTF8.self))
    }

    /// `-n` never prompts: without the grant this fails immediately with a message,
    /// which is what an unattended CLI or skill needs.
    private func sudo(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SleepFlagError.commandFailed(
                status: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
