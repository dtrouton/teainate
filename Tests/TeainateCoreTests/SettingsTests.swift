import Testing
import Foundation
@testable import TeainateCore

private func tempSettings() -> SettingsStore {
    SettingsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("teainate-settings-\(UUID().uuidString)/settings.json"))
}

@Test func missingFileYieldsDefaultWithoutWarning() {
    let (settings, warning) = tempSettings().read()
    #expect(settings.batteryFloor == 15)
    #expect(warning == nil)
}

@Test func writeThenReadRoundTrips() throws {
    let store = tempSettings()
    try store.write(Settings(batteryFloor: 30))
    #expect(store.read().settings.batteryFloor == 30)
}

@Test func emptyFileFallsBackToDefaultWithWarning() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "".write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 15)
    #expect(warning?.contains("settings.json") == true)
}

@Test func invalidJSONFallsBackToDefaultWithWarning() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ nope".write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 15)
    #expect(warning?.contains("settings.json") == true)
}

@Test func outOfRangeFloorOnDiskFallsBackToDefault() throws {
    let store = tempSettings()
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"battery_floor": 2}"#.write(to: store.fileURL, atomically: true, encoding: .utf8)
    let (settings, warning) = store.read()
    #expect(settings.batteryFloor == 15)
    #expect(warning != nil)
}

@Test func writeRefusesOutOfRangeFloor() {
    #expect(throws: SettingsError.floorOutOfRange(51)) { try tempSettings().write(Settings(batteryFloor: 51)) }
    #expect(throws: SettingsError.floorOutOfRange(4)) { try tempSettings().write(Settings(batteryFloor: 4)) }
}

@Test func standardPathsSitBesideTheStateFile() {
    let paths = TeainatePaths.standard(home: URL(fileURLWithPath: "/Users/x"))
    #expect(paths.settingsFile.path == "/Users/x/Library/Application Support/teainate/settings.json")
    #expect(paths.lidWatchLog.path == "/Users/x/Library/Application Support/teainate/lid-watch.log")
}
