import Carbon
import Foundation

struct HotKeyChoice: Equatable {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let choices: [HotKeyChoice] = [
        .init(title: "⌃⌥⌘T", keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .init(title: "⌃⌥⌘G", keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .init(title: "⌃⌥⌘W", keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        .init(title: "⌃⌥⌘Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey)),
    ]
}

final class HotKeyManager {
    private static var nextIdentifier: UInt32 = 1
    private let identifier: EventHotKeyID
    private var hotKey: EventHotKeyRef?
    private var registeredChoice: HotKeyChoice?
    private var isSuspended = false
    var currentChoice: HotKeyChoice? { registeredChoice }
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        identifier = EventHotKeyID(signature: OSType(0x57544C52), id: Self.nextIdentifier)
        Self.nextIdentifier += 1
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
                  pressed.signature == manager.identifier.signature,
                  pressed.id == manager.identifier.id else { return OSStatus(eventNotHandledErr) }
            guard !manager.isSuspended else { return noErr }
            manager.action()
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        if isSuspended { registeredChoice = choice; return true }
        if registeredChoice?.keyCode == choice.keyCode,
           registeredChoice?.modifiers == choice.modifiers, hotKey != nil { return true }
        // Keep the previous binding if the new shortcut is unavailable.
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier, GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        unregister()
        hotKey = candidate
        registeredChoice = choice
        return true
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    @discardableResult
    func resume() -> Bool {
        guard isSuspended else { return true }
        isSuspended = false
        guard let choice = registeredChoice else { return true }
        registeredChoice = nil
        return register(choice)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredChoice = nil
    }
}
