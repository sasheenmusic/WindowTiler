// Run from the project root:
// swiftc Sources/WindowTilerApp/HotKey.swift Scripts/test-hotkeys.swift -o /tmp/windowtiler-hotkey-tests
// /tmp/windowtiler-hotkey-tests
// Add --dispatch-only in a sandbox without WindowServer registration access.
// Registers rare shortcuts briefly, then injects Carbon events into this
// process only. It does not synthesize keyboard input or move any windows.
import Carbon
import Darwin
import Foundation

@main
enum HotKeyRegressionTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func send(identifier: UInt32) throws {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  GetCurrentEventTime(), EventAttributes(0), &event)
        try require(created == noErr && event != nil, "Could not create an internal Carbon test event.")
        guard let event else { return }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: OSType(0x57544C52), id: identifier)
        let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
        try require(parameter == noErr, "Could not set the internal event identifier.")
        let delivered = SendEventToEventTarget(event, GetApplicationEventTarget())
        try require(delivered == noErr || delivered == OSStatus(eventNotHandledErr), "Internal event dispatch failed: \(delivered).")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        let firstChoice = HotKeyChoice(title: "Test F18", keyCode: UInt32(kVK_F18), modifiers: modifiers)
        let secondChoice = HotKeyChoice(title: "Test F19", keyCode: UInt32(kVK_F19), modifiers: modifiers)
        let reservedChoice = HotKeyChoice(title: "Test F20", keyCode: UInt32(kVK_F20), modifiers: modifiers)
        var firstCount = 0
        var secondCount = 0
        // HotKeyManager's counter starts at one in this fresh process.
        let first = HotKeyManager { firstCount += 1 }
        let second = HotKeyManager { secondCount += 1 }
        let blocker = HotKeyManager {}
        try send(identifier: 1)
        try require(firstCount == 1 && secondCount == 0, "First manager event reached the wrong callback.")
        try send(identifier: 2)
        try require(firstCount == 1 && secondCount == 1, "Second manager event reached the wrong callback.")
        try send(identifier: 999)
        try require(firstCount == 1 && secondCount == 1, "Unknown identifier fired a callback.")
        print("PASS: independent hotkey routing")

        // Simulates an event already queued before unregistering. This check
        // needs no WindowServer registration or actual keyboard input.
        first.suspend()
        try send(identifier: 1)
        try require(firstCount == 1, "Suspended shortcut handled a queued event.")
        try require(first.resume(), "Manager could not leave suspension.")
        print("PASS: suspension rejects already queued events")
        if CommandLine.arguments.contains("--dispatch-only") {
            print("PASS: dispatch checks; registration checks were not run")
            return
        }

        try require(first.register(firstChoice), "F18 test registration unavailable; run from the logged-in desktop.")
        try require(second.register(secondChoice), "F19 test registration unavailable; run from the logged-in desktop.")
        try require(blocker.register(reservedChoice), "F20 test registration unavailable; run from the logged-in desktop.")

        try require(!first.register(reservedChoice), "A reserved shortcut was incorrectly accepted.")
        try require(first.currentChoice == firstChoice, "Failed replacement discarded the old shortcut.")
        try send(identifier: 1)
        try require(firstCount == 2 && secondCount == 1, "Old callback stopped after failed replacement.")
        print("PASS: failed replacement preserves old shortcut")

        first.suspend()
        try send(identifier: 1)
        try require(firstCount == 2, "Suspended shortcut handled a queued event.")
        try require(first.resume(), "Suspended shortcut did not resume.")
        try send(identifier: 1)
        try require(firstCount == 3, "Resumed shortcut stopped handling events.")
        print("PASS: suspension ignores queued events and resumes")
        withExtendedLifetime((first, second, blocker)) {}
        print("PASS: all hotkey regression checks")
    }
}
