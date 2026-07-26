import Foundation

public protocol CaffeinateSpawning: Sendable {
    func spawn(flags: [String]) throws -> pid_t
    func terminate(pid: pid_t)
}

/// Spawns a real `/usr/bin/caffeinate`. The child is deliberately left to outlive us —
/// it reparents to launchd and keeps its power assertion, which is what allows the CLI
/// to exit immediately without dropping the hold.
public struct SystemCaffeinateSpawner: CaffeinateSpawning {
    public init() {}

    public func spawn(flags: [String]) throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = flags
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ServiceError.spawnFailed(error.localizedDescription)
        }
        return process.processIdentifier
    }

    public func terminate(pid: pid_t) {
        kill(pid, SIGTERM)
    }
}
