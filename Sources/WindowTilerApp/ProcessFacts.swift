import Darwin
import Foundation

/// How a process was started, read from the kernel without Accessibility, so
/// a discovery pass pays a few system calls per visible app and no app IPC.
/// Only the arguments are remembered: they cannot change for a running
/// process. Everything else is read every time, because it does change when
/// a parent exits (the child goes to launchd, and a few seconds later macOS
/// makes it responsible for itself). Anything that cannot be read is simply
/// unknown. Used from the main thread only.
final class ProcessFactsReader {
    struct Facts: Equatable {
        let parentPID: pid_t
        let responsiblePID: pid_t?
        let responsibleIsAlive: Bool
        /// Empty when they could not be read.
        let arguments: [String]
    }

    /// A process id is reused after its process exits; the start time tells
    /// two processes with the same id apart.
    struct StartTime: Equatable {
        let seconds: Int
        let microseconds: Int
    }

    private struct CachedArguments {
        let startTime: StartTime
        let arguments: [String]
    }

    private var cache: [pid_t: CachedArguments] = [:]
    private let kernelInfo: (pid_t) -> (parentPID: pid_t, startTime: StartTime)?
    private let readArguments: (pid_t) -> [String]?
    private let readResponsiblePID: (pid_t) -> pid_t?

    // Hooks let the cache and the facts that change be checked without real
    // processes; a test cannot otherwise cause a reused process id.
    init(kernelInfo: ((pid_t) -> (parentPID: pid_t, startTime: StartTime)?)? = nil,
         readArguments: ((pid_t) -> [String]?)? = nil,
         readResponsiblePID: ((pid_t) -> pid_t?)? = nil) {
        self.kernelInfo = kernelInfo ?? Self.kernelInfo
        self.readArguments = readArguments ?? Self.arguments
        self.readResponsiblePID = readResponsiblePID ?? Self.responsiblePID
    }

    /// Nil when the process does not exist (any more), so the caller treats
    /// its facts as unknown.
    func facts(for pid: pid_t) -> Facts? {
        guard let info = kernelInfo(pid) else {
            cache[pid] = nil
            return nil
        }
        let arguments: [String]
        if let cached = cache[pid], cached.startTime == info.startTime {
            arguments = cached.arguments
        } else if let read = readArguments(pid) {
            cache[pid] = CachedArguments(startTime: info.startTime, arguments: read)
            arguments = read
        } else {
            // Not remembered, so a failed read (another user's process, or
            // one still starting) is tried again rather than trusted.
            cache[pid] = nil
            arguments = []
        }
        let responsible = readResponsiblePID(pid)
        return Facts(parentPID: info.parentPID, responsiblePID: responsible,
                     responsibleIsAlive: responsible.map(Self.isAlive) ?? false, arguments: arguments)
    }

    /// Drops processes that have quit.
    func forget(except live: Set<pid_t>) {
        cache = cache.filter { live.contains($0.key) }
    }

    var cachedProcessCount: Int { cache.count }

    // MARK: - System calls

    private static func kernelInfo(of pid: pid_t) -> (parentPID: pid_t, startTime: StartTime)? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A missing process is not an error: the call succeeds with no data.
        guard pid > 0, sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return (info.kp_eproc.e_ppid, StartTime(seconds: Int(started.tv_sec), microseconds: Int(started.tv_usec)))
    }

    private static func arguments(of pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 returns the argument count as an Int32, the executable
    /// path, NUL padding, then the NUL-separated arguments and the
    /// environment. Only the arguments are wanted.
    static func parseArguments(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    /// libsystem's private lookup of the process macOS holds responsible for
    /// a process (the app a command was started from). Not in any header, so
    /// it is looked up by name. It answers -1 for processes it cannot see
    /// (root's, or none at all), and a future macOS may drop it; both are unknown.
    private static let responsibleLookup: (@convention(c) (pid_t) -> pid_t)? = {
        // -2 is RTLD_DEFAULT, a macro Swift cannot import: search every loaded image.
        let everyImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(everyImage, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsible = responsibleLookup?(pid), responsible > 0 else { return nil }
        return responsible
    }

    /// A process we may not signal still exists.
    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
