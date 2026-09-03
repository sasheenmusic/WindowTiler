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
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        unregister()
        let signature = OSType(0x57544C52) // "WTLR"
        let identifier = EventHotKeyID(signature: signature, id: 1)
        return RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
