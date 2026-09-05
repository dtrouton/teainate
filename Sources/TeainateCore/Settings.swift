import Foundation

public let defaultBatteryFloor = 15
public let batteryFloorRange = 5...50
public let batteryFloorChoices = [5, 10, 15, 20, 30, 40, 50]

public enum SettingsError: Error, Equatable {
    case floorOutOfRange(Int)
}

/// What a hold started from the menu gets unless the user changes it afterwards.
/// Persisted so a ticked box means the same thing next week — a physical switch does
/// not reset itself when you close the lid.
public struct NewHoldDefaults: Codable, Sendable, Equatable {
    public var display: Bool
    public var acOnly: Bool
    public var lidClosed: Bool

    public init(display: Bool = false, acOnly: Bool = false, lidClosed: Bool = false) {
        self.display = display
        self.acOnly = acOnly
        self.lidClosed = lidClosed
    }

    enum CodingKeys: String, CodingKey {
        case display
        case acOnly = "ac_only"
        case lidClosed = "lid_closed"
    }

    public static let off = NewHoldDefaults()

    public subscript(modifier: HoldModifier) -> Bool {
        get {
            switch modifier {
            case .display: return display
            case .acOnly: return acOnly
            case .lidClosed: return lidClosed
            }
        }
        set {
            switch modifier {
            case .display: display = newValue
            case .acOnly: acOnly = newValue
            case .lidClosed: lidClosed = newValue
            }
        }
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var batteryFloor: Int
    public var newHoldDefaults: NewHoldDefaults

    public init(batteryFloor: Int = defaultBatteryFloor, newHoldDefaults: NewHoldDefaults = .off) {
        self.batteryFloor = batteryFloor
        self.newHoldDefaults = newHoldDefaults
    }

    enum CodingKeys: String, CodingKey {
        case batteryFloor = "battery_floor"
        case newHoldDefaults = "new_hold_defaults"
    }

    /// Explicit so a settings.json written before new-hold defaults existed still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? defaultBatteryFloor
        newHoldDefaults = try c.decodeIfPresent(NewHoldDefaults.self, forKey: .newHoldDefaults) ?? .off
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
        guard let data = try? Data(contentsOf: fileURL) else {
            return (.default, nil)
        }
        guard !data.isEmpty,
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
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
