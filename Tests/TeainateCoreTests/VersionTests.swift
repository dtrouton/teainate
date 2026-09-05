import Testing
import Foundation
@testable import TeainateCore

// The skill's staleness check keys off `TeainateVersion.current`; the app bundle
// advertises `CFBundleShortVersionString`. Nothing ties them together at build time,
// so this test does: bump one without the other and it goes red.
@Test func bundleVersionMatchesSwiftVersion() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: plist)
    let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    #expect(dict?["CFBundleShortVersionString"] as? String == TeainateVersion.current)
}
