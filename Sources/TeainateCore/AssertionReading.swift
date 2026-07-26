import Foundation

public struct ForeignAssertion: Sendable, Equatable, Codable {
    public let pid: pid_t
    public let process: String
    public let type: String

    public init(pid: pid_t, process: String, type: String) {
        self.pid = pid
        self.process = process
        self.type = type
    }
}

public protocol AssertionReading: Sendable {
    func assertions() throws -> [ForeignAssertion]
}

/// Parses the "Listed by owning process:" section of `pmset -g assertions`.
///
/// Lines look like:
///   `   pid 640(Claude): [0x00000044000181fd] 01:31:43 NoIdleSleepAssertion named: "Electron"`
/// Indented continuation lines (Details/Localized/Timeout) and the kernel section are ignored.
public func parseAssertions(_ text: String) -> [ForeignAssertion] {
    let pattern = #"^\s*pid (\d+)\(([^)]*)\):\s*\[[^\]]*\]\s+\S+\s+(\S+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    var results: [ForeignAssertion] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let string = String(line)
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let pidRange = Range(match.range(at: 1), in: string),
              let nameRange = Range(match.range(at: 2), in: string),
              let typeRange = Range(match.range(at: 3), in: string),
              let pid = pid_t(string[pidRange])
        else { continue }
        results.append(ForeignAssertion(
            pid: pid,
            process: String(string[nameRange]),
            type: String(string[typeRange])
        ))
    }
    return results
}

public struct PMSetAssertionReader: AssertionReading {
    public init() {}

    public func assertions() throws -> [ForeignAssertion] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseAssertions(String(decoding: data, as: UTF8.self))
    }
}
