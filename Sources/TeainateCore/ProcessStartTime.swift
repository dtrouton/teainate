import Darwin
import Foundation

/// A process's start time as the kernel reports it, to the microsecond. Two processes
/// that reuse a PID cannot share one; comparing it alongside the PID closes the
/// recycling gap. Stored as integers so the JSON round trip is exact (ISO-8601 dates
/// would lose the microseconds).
public struct ProcessStartTime: Codable, Sendable, Equatable, Hashable {
    public let seconds: Int64
    public let microseconds: Int32

    public init(seconds: Int64, microseconds: Int32) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public protocol ProcessStartTimeReading: Sendable {
    /// nil when the process is gone, or belongs to another user (EPERM). Every hold
    /// process is ours, so nil for a recorded pid means "not the process we spawned".
    func startTime(of pid: pid_t) -> ProcessStartTime?
}

/// `proc_pidinfo(PROC_PIDTBSDINFO)` — the same field `ps -o lstart` prints, without
/// parsing text and without losing the microseconds.
public struct ProcPIDInfoStartTimeReader: ProcessStartTimeReading {
    public init() {}

    public func startTime(of pid: pid_t) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStartTime(seconds: Int64(info.pbi_start_tvsec),
                                microseconds: Int32(info.pbi_start_tvusec))
    }
}
