import Foundation

/// Filesystem locations teainate uses. Injectable so tests never touch the real home directory.
public struct TeainatePaths: Sendable {
    public let stateFile: URL
    public let skillDirectory: URL
    public let localBinDirectory: URL

    public init(stateFile: URL, skillDirectory: URL, localBinDirectory: URL) {
        self.stateFile = stateFile
        self.skillDirectory = skillDirectory
        self.localBinDirectory = localBinDirectory
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
