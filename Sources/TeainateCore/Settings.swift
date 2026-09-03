import Foundation

public let defaultBatteryFloor = 15
public let batteryFloorRange = 5...50
public let batteryFloorChoices = [5, 10, 15, 20, 30, 40, 50]

public enum SettingsError: Error, Equatable {
    case floorOutOfRange(Int)
}

public struct Settings: Codable, Sendable, Equatable {
    public var batteryFloor: Int

    public init(batteryFloor: Int = defaultBatteryFloor) {
        self.batteryFloor = batteryFloor
    }

    enum CodingKeys: String, CodingKey {
        case batteryFloor = "battery_floor"
    }

    public static let `default` = Settings()
}

/// `settings.json` beside `holds.json`. The menu writes it; everything reads it.
/// Bad content never crashes and never yields a riskier floor than the default.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() -> (settings: Settings, warning: String?) {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return (.default, nil)
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return (.default, "settings.json could not be read; using the default battery floor (\(defaultBatteryFloor)%)")
        }
        guard batteryFloorRange.contains(settings.batteryFloor) else {
            return (.default, "settings.json has battery_floor \(settings.batteryFloor), outside \(batteryFloorRange.lowerBound)–\(batteryFloorRange.upperBound); using \(defaultBatteryFloor)%")
        }
        return (settings, nil)
    }

    public func write(_ settings: Settings) throws {
        guard batteryFloorRange.contains(settings.batteryFloor) else {
            throw SettingsError.floorOutOfRange(settings.batteryFloor)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
