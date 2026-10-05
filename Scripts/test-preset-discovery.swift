// Pure CG snapshot tests: no Accessibility calls or live window operations.
import AppKit

@main enum PresetDiscoveryTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func row(_ id: Int, pid: Int, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: layer]
    }
    static func main() {
        let eligiblePIDs = Set((1...64).map(pid_t.init))
        let rows = [row(11, pid: 1), row(12, pid: 2), row(11, pid: 1),
                    row(13, pid: 3, layer: 25), row(14, pid: 100),
                    [kCGWindowLayer as String: 0],
                    [kCGWindowLayer as String: 0, kCGWindowNumber as String: NSNumber(value: 15)]]
        let snapshot = PresetWindowService.shownWindowSnapshot(from: rows, eligiblePIDs: eligiblePIDs)
        require(snapshot.ids == [11, 12], "Snapshot admitted overlay, ineligible, or malformed windows")
        require(snapshot.pids == [1, 2], "Snapshot admitted background-only or ineligible apps")
        let empty = PresetWindowService.shownWindowSnapshot(from: [], eligiblePIDs: eligiblePIDs)
        require(empty.ids.isEmpty && empty.pids.isEmpty, "Empty screen queried background apps")
        let quarantine = AppQuarantine.shared
        quarantine.add(3)
        require(!snapshot.pids.contains(where: quarantine.contains), "Unshown quarantined app blocked capture")
        quarantine.add(2)
        require(snapshot.pids.contains(where: quarantine.contains), "Shown quarantined app failed to block partial capture")
        print("PASS: 5 discovery assertions")
        print("QUERY COUNT (CG fixture): candidate AX app enumerations \(eligiblePIDs.count) → \(snapshot.pids.count)")
    }
}
