import Foundation

/// The watcher's log lives beside whichever state file it was given, so a test
/// pointed at a temp directory never writes into the real one.
public func lidWatchLogURL(besideStateFile stateFile: URL) -> URL {
    stateFile.deletingLastPathComponent().appendingPathComponent("lid-watch.log")
}

/// Filesystem locations teainate uses. Injectable so tests never touch the real home directory.
public struct TeainatePaths: Sendable {
    public let stateFile: URL
    public let skillDirectory: URL
    public let localBinDirectory: URL
    public let settingsFile: URL
    public var lidWatchLog: URL { lidWatchLogURL(besideStateFile: stateFile) }

    public init(stateFile: URL, skillDirectory: URL, localBinDirectory: URL, settingsFile: URL? = nil) {
        self.stateFile = stateFile
        self.skillDirectory = skillDirectory
        self.localBinDirectory = localBinDirectory
        self.settingsFile = settingsFile
            ?? stateFile.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> TeainatePaths {
        TeainatePaths(
            stateFile: home
                .appendingPathComponent("Library/Application Support/teainate/holds.json"),
            skillDirectory: home
                .appendingPathComponent(".claude/skills/teainate"),
            localBinDirectory: home
                .appendingPathComponent(".local/bin")
        )
    }
}
