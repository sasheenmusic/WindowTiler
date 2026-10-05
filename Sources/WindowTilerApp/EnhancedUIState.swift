import AppKit
import ApplicationServices

/// One owner for the temporary Electron Accessibility flag. A lease keeps a
/// deferred cleanup from restoring the flag during another tiling operation.
/// Failed cleanup remains owned until it succeeds or the app exits; retries
/// back off so an unresponsive app cannot cause a tight loop.
final class EnhancedUIState {
    struct Lease: Hashable { fileprivate let id: UUID }
    private struct State {
        var users = 0
        var failures = 0
        var nextRetry = Date.distantPast
    }
    static let shared = EnhancedUIState()

    private let quarantine: AppQuarantine
    private let readFlag: (pid_t) -> Bool?
    private let writeFlag: (pid_t, Bool) -> AXError
    private let isAlive: (pid_t) -> Bool
    private let now: () -> Date
    private let schedulesRetries: Bool
    private var states: [pid_t: State] = [:]
    private var leases: [Lease: Set<pid_t>] = [:]
    private var retry: DispatchWorkItem?

    // Hooks let the restoration lifecycle be checked without operating apps.
    init(quarantine: AppQuarantine = .shared,
         readFlag: ((pid_t) -> Bool?)? = nil,
         writeFlag: ((pid_t, Bool) -> AXError)? = nil,
         isAlive: ((pid_t) -> Bool)? = nil,
         now: @escaping () -> Date = Date.init,
         schedulesRetries: Bool = true) {
        self.quarantine = quarantine
        self.readFlag = readFlag ?? { pid in
            let app = Self.element(pid)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
            if status == .cannotComplete { quarantine.add(pid) }
            return status == .success ? value as? Bool : nil
        }
        self.writeFlag = writeFlag ?? { pid, value in
            AXUIElementSetAttributeValue(Self.element(pid), "AXEnhancedUserInterface" as CFString,
                                         value ? kCFBooleanTrue : kCFBooleanFalse)
        }
        self.isAlive = isAlive ?? { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
        self.now = now
        self.schedulesRetries = schedulesRetries
    }

    func begin(for pids: Set<pid_t>) -> Lease {
        pruneExitedApps()
        let lease = Lease(id: UUID())
        var owned = Set<pid_t>()
        for pid in pids.sorted() where isAlive(pid) {
            if var state = states[pid] {
                if state.users == 0, !quarantine.contains(pid) {
                    // A failed restore acknowledgement may still have set
                    // the remote flag true. Reassert the leased value before
                    // another operation, retaining cleanup responsibility.
                    let status = writeFlag(pid, false)
                    if status == .cannotComplete { quarantine.add(pid) }
                    if status == .success { state.failures = 0 }
                }
                state.users += 1
                states[pid] = state
                owned.insert(pid)
                continue
            }
            guard !quarantine.contains(pid), readFlag(pid) == true else { continue }
            // Retain responsibility even for a timeout: the remote app may
            // have accepted a write whose acknowledgement did not arrive.
            states[pid] = State(users: 1)
            owned.insert(pid)
            if writeFlag(pid, false) == .cannotComplete { quarantine.add(pid) }
        }
        leases[lease] = owned
        scheduleRetry()
        return lease
    }

    func end(_ lease: Lease) {
        guard let pids = leases.removeValue(forKey: lease) else { return }
        for pid in pids {
            guard var state = states[pid] else { continue }
            state.users = max(0, state.users - 1)
            state.nextRetry = now()
            states[pid] = state
        }
        restorePending()
    }

    func restorePending() {
        pruneExitedApps()
        let current = now()
        for (pid, var state) in states where state.users == 0 && state.nextRetry <= current {
            if quarantine.contains(pid) {
                state.nextRetry = current.addingTimeInterval(quarantine.cooldown + 0.5)
                states[pid] = state
                continue
            }
            let status = writeFlag(pid, true)
            if status == .success { states[pid] = nil; continue }
            if status == .cannotComplete { quarantine.add(pid) }
            state.failures += 1
            let delay = min(60, 5.5 * pow(2, Double(min(state.failures - 1, 4))))
            state.nextRetry = current.addingTimeInterval(delay)
            states[pid] = state
            if state.failures == 3 {
                Log.tiling.warning("Accessibility UI flag restoration for pid \(pid) remains pending; retrying slowly")
            }
        }
        scheduleRetry()
    }

    var pendingPIDs: Set<pid_t> { Set(states.filter { $0.value.users == 0 }.keys) }

    private func pruneExitedApps() { states = states.filter { isAlive($0.key) } }

    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        guard schedulesRetries, let next = states.values.filter({ $0.users == 0 }).map(\.nextRetry).min() else { return }
        let item = DispatchWorkItem { [weak self] in self?.restorePending() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, next.timeIntervalSince(now())), execute: item)
    }

    private static func element(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }
}
