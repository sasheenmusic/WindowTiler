import AppKit
import ApplicationServices
import WindowTilerCore

struct TestApp {
    let processIdentifier: pid_t
    var isHidden = false
    var activationPolicy: NSApplication.ActivationPolicy {
        TestOS.policyReads[processIdentifier, default: 0] += 1
        return .regular
    }
    let isTerminated = false
    let localizedName: String? = "Test app"
    let bundleIdentifier: String? = "test.discovery"
}
struct TestScreen { let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000); var visibleFrame: CGRect { frame } }

// The runner redirects only OS discovery calls in a temporary source copy.
// Native mutation calls are trapped; this test cannot operate app windows.
enum TestOS {
    struct Node { let pid: pid_t; let id: CGWindowID; let attributes: [String: AnyObject]; var fails = false }
    static let mainPID: pid_t = 999001
    static let offscreenPID: pid_t = 999002
    static let hiddenPID: pid_t = 999003
    static let hungPID: pid_t = 999004
    static var runningApplications = [TestApp(processIdentifier: mainPID), TestApp(processIdentifier: offscreenPID), TestApp(processIdentifier: hiddenPID, isHidden: true), TestApp(processIdentifier: hungPID)]
    static let screens = [TestScreen()]
    static var generation = 0
    static var nodes: [UInt: Node] = [:]
    static var retained: [AXUIElement] = []
    static var roots: [pid_t: Int] = [:]
    static var reads: [pid_t: Int] = [:]
    static var policyReads: [pid_t: Int] = [:]
    static var cgReads = 0
    static var shown = [mainPID, hiddenPID]
    static func key(_ element: AXUIElement) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque()) }
    static func point(_ value: CGPoint) -> AXValue { var value = value; return AXValueCreate(.cgPoint, &value)! }
    static func size(_ value: CGSize) -> AXValue { var value = value; return AXValueCreate(.cgSize, &value)! }
    static func window(_ pid: pid_t, id: CGWindowID, small: Bool) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        retained.append(element)
        nodes[key(element)] = Node(pid: pid, id: id, attributes: [
            kAXRoleAttribute: kAXWindowRole as NSString,
            kAXSubroleAttribute: (small ? kAXDialogSubrole : kAXStandardWindowSubrole) as NSString,
            kAXModalAttribute: NSNumber(value: false), kAXMinimizedAttribute: NSNumber(value: false),
            "AXFullScreen": NSNumber(value: false), kAXTitleAttribute: "Fixture" as NSString,
            kAXPositionAttribute: point(CGPoint(x: 0, y: 30)),
            kAXSizeAttribute: size(small ? CGSize(width: 66, height: 20) : CGSize(width: 800, height: 900))
        ])
        return element
    }
    static func createApplication(_ pid: pid_t) -> AXUIElement {
        roots[pid, default: 0] += 1
        let element = AXUIElementCreateApplication(pid)
        retained.append(element)
        let children: [AXUIElement] = pid == mainPID
            ? [window(pid, id: 9, small: true)] + (generation == 0 ? [] : [window(pid, id: 1, small: false)]) : []
        nodes[key(element)] = Node(pid: pid, id: 0, attributes: [kAXWindowsAttribute: children as NSArray], fails: pid != mainPID)
        return element
    }
    static func copyAttribute(_ element: AXUIElement, _ name: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
        guard let node = nodes[key(element)] else { return .invalidUIElement }
        reads[node.pid, default: 0] += 1
        if node.fails { return .cannotComplete }
        guard let result = node.attributes[name as String] else { return .attributeUnsupported }
        value.pointee = result
        return .success
    }
    static func isSettable(_ element: AXUIElement, _ name: CFString, _ value: UnsafeMutablePointer<DarwinBoolean>) -> AXError {
        value.pointee = DarwinBoolean(true)
        return .success
    }
    static func windowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError {
        guard let node = nodes[key(element)] else { return .invalidUIElement }
        id.pointee = node.id
        return .success
    }
    static func mutation(_ element: AXUIElement, _ name: CFString, _ value: CFTypeRef) -> AXError {
        fatalError("Discovery must never mutate a window")
    }
    static func cgList(_ options: CGWindowListOption, _ relative: CGWindowID) -> CFArray? {
        cgReads += 1
        return shown.map { pid in [
            kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: 0,
            kCGWindowNumber as String: pid == mainPID ? 1 : 2,
            kCGWindowBounds as String: ["X": 0, "Y": 30, "Width": 800, "Height": 900]
        ] as [String: Any] } as CFArray
    }
}

var assertions = 0
func check(_ value: Bool, _ name: String) { precondition(value, name); assertions += 1; print("PASS \(name)") }
let tiler = WindowTiler()
let first = tiler.windowTopologySignature()
check(first != nil && !first!.contains("\(TestOS.mainPID)@"), "old AX generation has only rejected tiny helper")
TestOS.generation = 1
let second = tiler.windowTopologySignature()
check(second?.contains("\(TestOS.mainPID)@") == true, "fresh AX root sees replaced main tree without PID change")
check(TestOS.roots[TestOS.mainPID] == 2, "one fresh local AX root per discovery scan")
check(TestOS.roots[TestOS.offscreenPID] == nil && TestOS.roots[TestOS.hiddenPID] == nil, "offscreen and hidden apps receive no AX discovery calls")
let backgroundPIDs = (999100..<999200).map { pid_t($0) }
TestOS.runningApplications += backgroundPIDs.map { TestApp(processIdentifier: $0) }
TestOS.policyReads = [:]
let rootsBeforeSnapshot = TestOS.roots[TestOS.mainPID] ?? 0
let readsBeforeSnapshot = TestOS.reads[TestOS.mainPID] ?? 0
let cgBeforeSnapshot = TestOS.cgReads
let snapshot = tiler.windowTopologyAndCounts()
let snapshotAXReads = (TestOS.reads[TestOS.mainPID] ?? 0) - readsBeforeSnapshot
check(snapshot?.signature == second && snapshot?.counts == [1], "one snapshot returns the same topology and display counts")
check(TestOS.cgReads - cgBeforeSnapshot == 1 && (TestOS.roots[TestOS.mainPID] ?? 0) - rootsBeforeSnapshot == 1,
      "combined panel and topology snapshot uses one CG list and one fresh AX root")
check(TestOS.policyReads.count == 2 && TestOS.policyReads[TestOS.offscreenPID] == nil
      && backgroundPIDs.allSatisfy { TestOS.policyReads[$0] == nil }, "102 offscreen apps receive no dynamic activation-policy queries")
let readsBeforeSeparate = TestOS.reads[TestOS.mainPID] ?? 0
_ = tiler.windowCountsPerScreen(); _ = tiler.windowTopologySignature()
check((TestOS.reads[TestOS.mainPID] ?? 0) - readsBeforeSeparate == snapshotAXReads * 2,
      "shared snapshot halves AX reads compared with separate panel and topology scans")
print("MEASURE combined snapshot: \(snapshotAXReads) AX reads, 1 CG read; separate scans: \(snapshotAXReads * 2) AX reads, 2 CG reads; app policy queries: 2 of \(TestOS.runningApplications.count)")
AppQuarantine.shared.add(TestOS.offscreenPID)
check(tiler.windowCountsPerScreen() == [1], "offscreen quarantine does not block visible count")
check(AppQuarantine.shared.contains(TestOS.offscreenPID), "offscreen live app keeps its quarantine until recovery or exit")
check(tiler.windowTopologySignature()?.contains("\(TestOS.mainPID)@") == true, "offscreen quarantine does not block automatic topology")
TestOS.shown.append(TestOS.hungPID)
check(tiler.windowTopologySignature() == nil, "visible unresponsive app keeps topology unknown")
check(tiler.windowTopologyAndCounts() == nil, "combined snapshot remains unknown while a visible app is quarantined")
check(TestOS.reads[TestOS.hungPID] == 1, "first timeout stops all further reads to that app")
TestOS.shown.removeAll { $0 == TestOS.hungPID }
check(tiler.windowCountsPerScreen() == [1], "moving quarantined app offscreen restores visible discovery")
tiler.resetAccessibilityState()
check(AppQuarantine.shared.pids.isEmpty, "permission recovery clears stale quarantine")
print("RESULT \(assertions) discovery assertions passed")

// Shared flag cleanup lifecycle; every app/read/write is an injected fake.
final class Clock { var date = Date(timeIntervalSince1970: 1000); func advance(_ seconds: Double = 100) { date = date.addingTimeInterval(seconds) } }
let clock = Clock()
let quarantine = AppQuarantine(now: { clock.date })
var flag = true
var writes: [Bool] = []
var alive = true
let shared = EnhancedUIState(quarantine: quarantine, readFlag: { _ in flag }, writeFlag: { _, value in writes.append(value); flag = value; return .success }, isAlive: { _ in alive }, now: { clock.date }, schedulesRetries: false)
let one = shared.begin(for: [42]); let two = shared.begin(for: [42])
shared.end(one); shared.restorePending()
check(writes == [false] && !flag, "nested lease prevents another owner's cleanup from re-enabling flag")
shared.end(two)
check(writes == [false, true] && flag, "last lease restores original flag once")
shared.end(two)
check(writes == [false, true], "duplicate lease release is harmless")
flag = false; writes = []
shared.end(shared.begin(for: [42]))
check(writes.isEmpty && !flag, "original false flag is left unchanged")

flag = true; var restoreAllowed = false
let failing = EnhancedUIState(quarantine: quarantine, readFlag: { _ in flag }, writeFlag: { _, value in
    if value && !restoreAllowed { return .failure }
    flag = value; return .success
}, isAlive: { _ in alive }, now: { clock.date }, schedulesRetries: false)
failing.end(failing.begin(for: [43]))
for _ in 0..<3 { clock.advance(); failing.restorePending() }
check(failing.pendingPIDs == [43] && !flag, "more than three failed restores retain original flag responsibility")
restoreAllowed = true; clock.advance(); failing.restorePending()
check(failing.pendingPIDs.isEmpty && flag, "later recovery restores flag and clears pending state")
restoreAllowed = false; failing.end(failing.begin(for: [43])); alive = false
failing.restorePending()
check(failing.pendingPIDs.isEmpty, "exited apps are pruned from cleanup")

alive = true; flag = true
let timedOut = EnhancedUIState(quarantine: quarantine, readFlag: { _ in flag }, writeFlag: { _, value in
    flag = value; return value ? .success : .cannotComplete
}, isAlive: { _ in alive }, now: { clock.date }, schedulesRetries: false)
timedOut.end(timedOut.begin(for: [44]))
check(timedOut.pendingPIDs == [44] && !flag && quarantine.contains(44), "ambiguous timed-out disable still owns restoration")
clock.advance(6); timedOut.restorePending()
check(timedOut.pendingPIDs.isEmpty && flag, "timeout cooldown permits eventual cleanup")

flag = true; var failAcknowledgement = true
let ambiguous = EnhancedUIState(quarantine: quarantine, readFlag: { _ in flag }, writeFlag: { _, value in
    flag = value
    return value && failAcknowledgement ? .cannotComplete : .success
}, isAlive: { _ in true }, now: { clock.date }, schedulesRetries: false)
ambiguous.end(ambiguous.begin(for: [45]))
check(flag && ambiguous.pendingPIDs == [45], "failed acknowledgement can still have restored remote flag")
clock.advance(6)
let renewed = ambiguous.begin(for: [45])
check(!flag, "reacquiring pending lease reasserts disabled flag")
ambiguous.restorePending()
check(!flag, "stale retry cannot re-enable flag during renewed lease")
failAcknowledgement = false; ambiguous.end(renewed)
check(flag && ambiguous.pendingPIDs.isEmpty, "renewed lease restores original flag after operation")
print("RESULT \(assertions) total assertions passed")
