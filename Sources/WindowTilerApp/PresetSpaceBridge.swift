import AppKit
import Darwin
import ObjectiveC

/// Optional, dynamically resolved WindowServer APIs. No system settings or
/// security changes are needed. A successful request is never movement proof;
/// callers must read the window's Space membership again after settling.
/// Modern move sequence follows Hammerspoon's hs.spaces implementation:
/// https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m
final class PresetSpaceBridge {
    typealias SpaceID = UInt64
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private typealias Compat = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias Workspace = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
    private typealias LegacyMove = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias BridgedMove = @convention(c) (UnsafeMutableRawPointer) -> Int64
    private typealias SpaceWindows = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer?
    private let connection: Int32?
    private let displays: Displays?
    private let membership: Membership?
    private let spaceType: SpaceType?
    private let compat: Compat?
    private let workspace: Workspace?
    private let legacyMove: LegacyMove?
    private let bridgedMove: BridgedMove?
    private let spaceWindows: SpaceWindows?

    init() {
        let loaded = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        handle = loaded
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let loaded, let symbol = dlsym(loaded, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        connection = resolve("SLSMainConnectionID", as: Connection.self)?()
        displays = resolve("SLSCopyManagedDisplaySpaces", as: Displays.self)
        membership = resolve("SLSCopySpacesForWindows", as: Membership.self)
        spaceType = resolve("SLSSpaceGetType", as: SpaceType.self)
        compat = resolve("SLSSpaceSetCompatID", as: Compat.self)
        workspace = resolve("SLSSetWindowListWorkspace", as: Workspace.self)
        legacyMove = resolve("SLSMoveWindowsToManagedSpace", as: LegacyMove.self)
        spaceWindows = resolve("SLSCopyWindowsWithOptionsAndTags", as: SpaceWindows.self)
        if let exported = resolve("SLSPerformAsynchronousBridgedWindowManagementOperation", as: BridgedMove.self) {
            bridgedMove = exported
        } else if let symbol = PresetPrivateSymbol.find(
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
            in: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        ) {
            bridgedMove = unsafeBitCast(symbol, to: BridgedMove.self)
        } else {
            bridgedMove = nil
        }
    }

    deinit { if let handle { dlclose(handle) } }

    func activeSpace(on displayID: String) -> SpaceID? {
        guard let connection, let displays,
              let records = displays(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let matching = records.first {
            ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(displayID) == .orderedSame
        }
        // With shared Spaces, WindowServer uses one "Main" record instead of
        // one per physical display. Never use another display's desktop when
        // separate Spaces are enabled.
        let record = matching ?? (!NSScreen.screensHaveSeparateSpaces ? records.first : nil)
        guard let current = record?["Current Space"] as? [String: Any],
              let number = current["ManagedSpaceID"] as? NSNumber else { return nil }
        return number.uint64Value
    }

    func activeDesktop(on displayID: String) -> SpaceID? {
        guard let space = activeSpace(on: displayID), isUserDesktop(space) else { return nil }
        return space
    }

    func spaces(of windowID: CGWindowID) -> [SpaceID]? {
        guard let connection, let membership,
              let result = membership(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return result.map(\.uint64Value)
    }

    func isUserDesktop(_ space: SpaceID) -> Bool {
        guard let connection, let spaceType else { return false }
        return spaceType(connection, space) == 0
    }

    func nonMinimizedWindows(on space: SpaceID) -> Set<CGWindowID>? {
        guard let connection, let spaceWindows, isUserDesktop(space) else { return nil }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let list = spaceWindows(connection, 0, [NSNumber(value: space)] as CFArray, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return Set(list.map(\.uint32Value))
    }

    /// Requests movement only between ordinary desktops. This deliberately
    /// does not force fullscreen/tiled Spaces or sticky (all-Spaces) windows.
    func requestMove(_ windowID: CGWindowID, to destination: SpaceID, evenIfAlreadyThere: Bool = false) -> String? {
        guard let source = spaces(of: windowID), !source.isEmpty else {
            return "Cannot read this window's desktop."
        }
        if source.contains(destination), !evenIfAlreadyThere { return nil }
        guard source.count == 1, source.allSatisfy(isUserDesktop), isUserDesktop(destination) else {
            return "This window is not on an ordinary desktop."
        }
        guard let connection else {
            return "Desktop movement is unavailable on this Mac."
        }
        // Tahoe replaced the old workspace operation. Resolve the operation
        // class and initializer too; a missing/private API fails safely.
        // https://github.com/asmvik/yabai/blob/master/src/space_manager.c
        if let bridgedMove {
            let allocateSelector = NSSelectorFromString("alloc")
            let initializeSelector = NSSelectorFromString("initWithWindows:spaceID:")
            guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
                  let allocateMethod = class_getClassMethod(cls, allocateSelector),
                  let initializeMethod = class_getInstanceMethod(cls, initializeSelector) else {
                return "Desktop movement is unavailable on this Mac."
            }
            typealias Allocate = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
            let allocate = unsafeBitCast(method_getImplementation(allocateMethod), to: Allocate.self)
            let initialize = unsafeBitCast(method_getImplementation(initializeMethod), to: Initialize.self)
            guard let allocated = allocate(cls as AnyObject, allocateSelector),
                  let operation = initialize(allocated.takeUnretainedValue(), initializeSelector,
                                             [NSNumber(value: windowID)] as NSArray, destination)?.takeRetainedValue() else {
                return "macOS could not prepare desktop movement."
            }
            // alloc/init returns +1. ARC releases it after dispatch just as
            // yabai does; WindowServer retains the asynchronous operation.
            _ = withExtendedLifetime(operation) { bridgedMove(Unmanaged.passUnretained(operation).toOpaque()) }
            return nil
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion < 14 || (version.majorVersion == 14 && version.minorVersion < 5) {
            guard let legacyMove else { return "Desktop movement is unavailable on this Mac." }
            legacyMove(connection, [NSNumber(value: windowID)] as CFArray, destination)
            return nil
        }
        guard let compat, let workspace else { return "Desktop movement is unavailable on this Mac." }
        var window = windowID
        let tag: Int32 = 0x79616265
        guard compat(connection, destination, tag) == 0 else {
            return "macOS refused desktop movement."
        }
        // Always clear our temporary compatibility ID, including errors.
        let status = workspace(connection, &window, 1, tag)
        let reset = compat(connection, destination, 0)
        guard status == 0, reset == 0 else { return "macOS refused desktop movement." }
        return nil
    }
}
