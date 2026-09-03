import Foundation

/// Apps that failed to answer an Accessibility request in time. Shared by
/// the tiler and the event monitor so the first timeout anywhere suppresses
/// every later request to that app until the cooldown ends.
final class AppQuarantine {
    static let shared = AppQuarantine()

    let cooldown: TimeInterval = 5
    private var until: [pid_t: Date] = [:]

    func contains(_ pid: pid_t) -> Bool {
        guard let date = until[pid] else { return false }
        return date > Date()
    }

    func add(_ pid: pid_t) {
        guard !contains(pid) else { return }
        until[pid] = Date().addingTimeInterval(cooldown)
        Log.tiling.warning("pid \(pid) did not answer in time; leaving it alone for \(self.cooldown) s")
    }

    var pids: [pid_t] { until.filter { $0.value > Date() }.keys.sorted() }

    func forget(except live: Set<pid_t>) {
        until = until.filter { live.contains($0.key) && $0.value > Date() }
    }
}
