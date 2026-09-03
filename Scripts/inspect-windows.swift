import AppKit
import ApplicationServices

func attribute(_ name: String, from element: AXUIElement) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func point(_ name: String, from element: AXUIElement) -> CGPoint? {
    guard let value = attribute(name, from: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
}

func size(_ name: String, from element: AXUIElement) -> CGSize? {
    guard let value = attribute(name, from: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
}

func settable(_ name: String, on element: AXUIElement) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
}

for (index, screen) in NSScreen.screens.enumerated() {
    print("SCREEN \(index) frame=\(screen.frame) visible=\(screen.visibleFrame)")
}

let apps = NSWorkspace.shared.runningApplications
    .filter { $0.activationPolicy == .regular && !$0.isTerminated }
    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

for app in apps {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windows = attribute(kAXWindowsAttribute, from: root) as? [AXUIElement] ?? []
    print("APP \(app.localizedName ?? "?") pid=\(app.processIdentifier) hidden=\(app.isHidden) windows=\(windows.count)")
    for window in windows {
        let title = (attribute(kAXTitleAttribute, from: window) as? String) ?? ""
        let role = (attribute(kAXRoleAttribute, from: window) as? String) ?? "?"
        let subrole = (attribute(kAXSubroleAttribute, from: window) as? String) ?? "?"
        let minimized = (attribute(kAXMinimizedAttribute, from: window) as? Bool) ?? false
        print("  title=\(title.debugDescription) role=\(role) subrole=\(subrole) minimized=\(minimized) sizeSettable=\(settable(kAXSizeAttribute, on: window)) position=\(String(describing: point(kAXPositionAttribute, from: window))) size=\(String(describing: size(kAXSizeAttribute, from: window)))")
    }
}
