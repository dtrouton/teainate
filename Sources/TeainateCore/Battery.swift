import Foundation

public enum PowerSource: String, Sendable, Codable, Equatable {
    case ac, battery
}

public struct BatteryState: Sendable, Equatable {
    public let source: PowerSource
    /// nil on a Mac with no battery.
    public let percent: Int?

    public init(source: PowerSource, percent: Int?) {
        self.source = source
        self.percent = percent
    }
}

public protocol BatteryReading: Sendable {
    /// nil means the output could not be parsed. Callers treat that as "unknown",
    /// never as "on battery" or "at the floor".
    func read() throws -> BatteryState?
}

/// Parses `pmset -g batt`. First line: `Now drawing from 'Battery Power'` or `'AC Power'`.
/// Optional second line: ` -InternalBattery-0 (id=…)<tab>83%; discharging; …`.
public func parseBatteryOutput(_ text: String) -> BatteryState? {
    let lines = text.split(separator: "\n").map(String.init)
    guard let sourceLine = lines.first(where: { $0.contains("Now drawing from") }) else { return nil }
    let source: PowerSource = sourceLine.contains("Battery Power") ? .battery : .ac

    var percent: Int?
    if let batteryLine = lines.first(where: { $0.contains("InternalBattery") }),
       let range = batteryLine.range(of: #"\d+%"#, options: .regularExpression) {
        percent = Int(batteryLine[range].dropLast())
    }
    return BatteryState(source: source, percent: percent)
}

public struct PMSetBatteryReader: BatteryReading {
    public init() {}

    public func read() throws -> BatteryState? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBatteryOutput(String(decoding: data, as: UTF8.self))
    }
}
