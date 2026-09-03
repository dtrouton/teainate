import Foundation

public enum GrantError: Error, Equatable {
    case invalidUsername
}

public protocol PrivilegeGranting: Sendable {
    /// A file read, never a `sudo -n` probe: `status` must stay cheap and must never prompt.
    func isGranted() -> Bool
}

/// The one-time grant that lets `sudo -n pmset -a disablesleep 0|1` run without a
/// password. sudoers matches arguments literally, so nothing else can be run through it.
public struct SudoersGrant: PrivilegeGranting {
    public let username: String
    public let directory: URL

    public init(
        username: String = NSUserName(),
        directory: URL = URL(fileURLWithPath: "/etc/sudoers.d")
    ) {
        self.username = username
        self.directory = directory
    }

    public var rule: String {
        "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    /// Per-user so two users on one Mac cannot overwrite each other's grant. sudo
    /// ignores files whose names contain '.', so a dotted username is mangled.
    public var fileURL: URL {
        directory.appendingPathComponent("teainate-" + username.replacingOccurrences(of: ".", with: "_"))
    }

    public func isGranted() -> Bool {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) == rule
    }

    /// Bourne shell, run as root by the app's admin dialog. Writes to a `.tmp` sibling
    /// (ignored by sudo while it exists), validates, then moves into place.
    public func installScript() throws -> String {
        try validateUsername()
        let file = fileURL.path
        return """
        set -e
        umask 077
        printf '%s\\n' '\(rule)' > '\(file).tmp'
        chmod 0440 '\(file).tmp'
        if /usr/sbin/visudo -c -f '\(file).tmp' >/dev/null 2>&1; then
          mv '\(file).tmp' '\(file)'
        else
          rm -f '\(file).tmp'
          exit 1
        fi
        """
    }

    public func removeScript() throws -> String {
        try validateUsername()
        return "rm -f '\(fileURL.path)'"
    }

    private func validateUsername() throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !username.isEmpty,
              username.unicodeScalars.allSatisfy(allowed.contains)
        else { throw GrantError.invalidUsername }
    }
}
