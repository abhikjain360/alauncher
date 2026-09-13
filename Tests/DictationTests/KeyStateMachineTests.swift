import Core
import Testing
@testable import Dictation

// Flags as the tap sees them: the generic mask plus the device bit for the side.
private let rightOption: UInt64 = 0x80000 | 0x40
private let leftOption: UInt64 = 0x80000 | 0x20
private let bothOptions: UInt64 = 0x80000 | 0x60
private let rightShift: UInt64 = 0x20000 | 0x4
private let leftCommand: UInt64 = 0x100000 | 0x8
private let leftControl: UInt64 = 0x40000 | 0x1

// Virtual key codes.
private let rightOptionKey: UInt16 = 61
private let leftOptionKey: UInt16 = 58
private let rightShiftKey: UInt16 = 60
private let commandKey: UInt16 = 55
private let controlKey: UInt16 = 59
private let mKey: UInt16 = 46
private let escapeKey: UInt16 = 53
private let aKey: UInt16 = 0

private let start = KeyDecision(action: .start)
private let stop = KeyDecision(action: .stop)
private let pass = KeyDecision()
private let swallow = KeyDecision(swallow: true)

/// Drives the machine like the tap does, with a fake system key state.
private struct Harness {
    var machine: KeyStateMachine
    var busy = false
    /// Keys the system reports as down, for the stale-key check.
    var systemKeysDown: Set<UInt16> = []

    init(bindings: KeyStateMachine.Bindings = KeyStateMachine.Bindings(Config().dictation)) {
        machine = KeyStateMachine(bindings: bindings)
    }

    mutating func send(_ event: KeyEvent) -> KeyDecision {
        let keys = systemKeysDown
        return machine.handle(event, busy: busy) { keys.contains($0) }
    }

    mutating func flags(_ flags: UInt64, key: UInt16 = rightOptionKey, userData: Int64 = 0) -> KeyDecision {
        send(KeyEvent(kind: .flagsChanged, keyCode: key, flags: flags, userData: userData))
    }

    mutating func down(_ key: UInt16, flags: UInt64 = 0, isRepeat: Bool = false, userData: Int64 = 0) -> KeyDecision {
        if !isRepeat { systemKeysDown.insert(key) }
        return send(KeyEvent(kind: .keyDown, keyCode: key, flags: flags, isRepeat: isRepeat, userData: userData))
    }

    mutating func up(_ key: UInt16, flags: UInt64 = 0, userData: Int64 = 0) -> KeyDecision {
        systemKeysDown.remove(key)
        return send(KeyEvent(kind: .keyUp, keyCode: key, flags: flags, userData: userData))
    }

    mutating func mouse() -> KeyDecision { send(KeyEvent(kind: .mouseDown)) }
    mutating func tapDisabled() -> KeyDecision { send(KeyEvent(kind: .tapDisabled)) }
}

@Test func holdStartsAndReleaseStops() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.machine.isRecording)
    #expect(keys.flags(0) == stop)
    #expect(!keys.machine.isRecording)
    // A second hold starts again.
    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(0) == stop)
}

@Test func leftOptionAloneNeverStarts() {
    var keys = Harness()
    #expect(keys.flags(leftOption, key: leftOptionKey) == pass)
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(0, key: leftOptionKey) == pass)
}

@Test func bothOptionsNeverStart() {
    var keys = Harness()
    // Left first, then right: both held, no start.
    #expect(keys.flags(leftOption, key: leftOptionKey) == pass)
    #expect(keys.flags(bothOptions) == pass)
    // Letting go of left leaves right alone, but a release never starts.
    #expect(keys.flags(rightOption, key: leftOptionKey) == pass)
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(0) == pass)

    // Right first starts; adding left cancels.
    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(bothOptions, key: leftOptionKey) == KeyDecision(action: .cancel(.otherModifier)))
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(rightOption, key: leftOptionKey) == pass)
    #expect(keys.flags(0) == pass)
}

@Test func genericOptionFlagWithoutDeviceBitsNeverStarts() {
    var keys = Harness()
    #expect(keys.flags(0x80000) == pass)
    #expect(!keys.machine.isRecording)
}

@Test func rightShiftAllowedWhileAssemblingTheRawChord() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(rightOption | rightShift, key: rightShiftKey) == pass)
    #expect(keys.machine.isRecording)
    #expect(keys.down(mKey, flags: rightOption | rightShift) == KeyDecision(swallow: true, action: .switchToRaw))
    #expect(keys.machine.isRaw)
    #expect(keys.down(mKey, flags: rightOption | rightShift, isRepeat: true) == swallow)
    #expect(keys.up(mKey, flags: rightOption | rightShift) == swallow)
    // Releasing Shift keeps recording; releasing Option stops in raw mode.
    #expect(keys.flags(rightOption, key: rightShiftKey) == pass)
    #expect(keys.machine.isRaw)
    #expect(keys.flags(0) == stop)
}

@Test func rawChordKeyStaysSwallowedAfterTheStop() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(rightOption | rightShift, key: rightShiftKey) == pass)
    #expect(keys.down(mKey, flags: rightOption | rightShift) == KeyDecision(swallow: true, action: .switchToRaw))
    // Option and Shift go up while M is still held.
    #expect(keys.flags(rightShift) == stop)
    #expect(keys.flags(0, key: rightShiftKey) == pass)
    #expect(keys.down(mKey, isRepeat: true) == swallow)
    #expect(keys.up(mKey) == swallow)
    // The key-up forgot M: a fresh press passes.
    #expect(keys.down(mKey) == pass)
    #expect(keys.up(mKey) == pass)
}

@Test func mWithoutShiftIsAnOtherKey() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(mKey, flags: rightOption) == KeyDecision(action: .cancel(.otherKey)))
    #expect(keys.up(mKey, flags: rightOption) == pass)
}

@Test func escapeCancelsAndStaysSwallowedAfterTheCancel() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(escapeKey, flags: rightOption) == KeyDecision(swallow: true, action: .cancel(.cancelKey)))
    #expect(!keys.machine.isRecording)
    #expect(keys.down(escapeKey, flags: rightOption, isRepeat: true) == swallow)
    #expect(keys.flags(0) == pass)
    #expect(keys.up(escapeKey) == swallow)
    // Forgotten after its key-up: Esc works normally again.
    #expect(keys.down(escapeKey) == pass)
    #expect(keys.up(escapeKey) == pass)
}

@Test func aFreshPressOfARememberedKeyIsANewPress() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(escapeKey, flags: rightOption) == KeyDecision(swallow: true, action: .cancel(.cancelKey)))
    #expect(keys.flags(0) == pass)
    // Esc's key-up never reached the tap. The next real press belongs to the frontmost app.
    #expect(keys.down(escapeKey) == pass)
    #expect(keys.up(escapeKey) == pass)
    // And Esc still cancels the next recording.
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(escapeKey, flags: rightOption) == KeyDecision(swallow: true, action: .cancel(.cancelKey)))
    #expect(keys.up(escapeKey, flags: rightOption) == swallow)
}

@Test func anotherKeyCancelsSilentlyAndPassesThrough() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(aKey, flags: rightOption) == KeyDecision(action: .cancel(.otherKey)))
    #expect(keys.down(aKey, flags: rightOption, isRepeat: true) == pass)
    #expect(keys.up(aKey, flags: rightOption) == pass)
    #expect(keys.flags(0) == pass)
}

@Test func mouseDownCancelsAndPassesThrough() {
    var keys = Harness()
    #expect(keys.mouse() == pass)
    #expect(keys.flags(rightOption) == start)
    #expect(keys.mouse() == KeyDecision(action: .cancel(.mouse)))
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(0) == pass)
}

@Test func anyOtherAddedModifierCancels() {
    for (flag, key) in [(leftCommand, commandKey), (leftControl, controlKey), (leftOption, leftOptionKey)] {
        var keys = Harness()
        #expect(keys.flags(rightOption) == start)
        #expect(keys.flags(rightOption | flag, key: key) == KeyDecision(action: .cancel(.otherModifier)))
        #expect(!keys.machine.isRecording)
        #expect(keys.flags(rightOption, key: key) == pass)
        #expect(keys.flags(0) == pass)
    }
}

@Test func releasingTheHoldKeyStopsEvenWithShiftStillHeld() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(rightOption | rightShift, key: rightShiftKey) == pass)
    #expect(keys.flags(rightShift) == stop)
    #expect(!keys.machine.isRaw)
}

@Test func escapeWhileBusyCancelsAndIsSwallowed() {
    var keys = Harness()
    keys.busy = true
    #expect(keys.down(escapeKey) == KeyDecision(swallow: true, action: .cancel(.cancelKey)))
    #expect(keys.down(escapeKey, isRepeat: true) == swallow)
    keys.busy = false
    #expect(keys.up(escapeKey) == swallow)

    // Not busy: Esc belongs to the frontmost app.
    #expect(keys.down(escapeKey) == pass)
    #expect(keys.up(escapeKey) == pass)

    // Busy, but Cmd+Option+Esc (Force Quit) isn't the cancel key.
    keys.busy = true
    #expect(keys.down(escapeKey, flags: leftCommand | leftOption) == pass)
    #expect(keys.up(escapeKey, flags: leftCommand | leftOption) == pass)
}

@Test func tapDisabledResetsEverything() {
    var keys = Harness()
    #expect(keys.tapDisabled() == pass)

    #expect(keys.flags(rightOption) == start)
    #expect(keys.flags(rightOption | rightShift, key: rightShiftKey) == pass)
    #expect(keys.down(mKey, flags: rightOption | rightShift) == KeyDecision(swallow: true, action: .switchToRaw))
    #expect(keys.tapDisabled() == KeyDecision(action: .cancel(.tapDisabled)))
    #expect(!keys.machine.isRecording)
    #expect(!keys.machine.isRaw)
    // Remembered keys were forgotten with the rest.
    #expect(keys.up(mKey) == pass)
    // Starting works again after the reset.
    #expect(keys.flags(0) == pass)
    #expect(keys.flags(rightOption) == start)
}

@Test func ourOwnEventsAreIgnored() {
    var keys = Harness()
    let magic = DictationConstants.eventUserData
    #expect(keys.flags(rightOption, userData: magic) == pass)
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(0, userData: magic) == pass)

    #expect(keys.flags(rightOption) == start)
    // Synthetic typing or Cmd+V during a recording neither cancels nor gets swallowed.
    #expect(keys.down(aKey, userData: magic) == pass)
    #expect(keys.up(aKey, userData: magic) == pass)
    #expect(keys.down(escapeKey, userData: magic) == pass)
    #expect(keys.flags(rightOption | leftCommand, key: commandKey, userData: magic) == pass)
    #expect(keys.machine.isRecording)
    #expect(keys.flags(0) == stop)
}

@Test func aHeldKeyBlocksTheStart() {
    var keys = Harness()
    #expect(keys.down(aKey) == pass)
    #expect(keys.flags(rightOption) == pass)
    #expect(!keys.machine.isRecording)
    #expect(keys.flags(0) == pass)
    #expect(keys.up(aKey) == pass)
    #expect(keys.flags(rightOption) == start)
}

@Test func aMissedKeyUpDoesNotBlockTheStartForever() {
    var keys = Harness()
    #expect(keys.down(aKey) == pass)
    // Its key-up never reached the tap (secure input), but the system says it's up.
    keys.systemKeysDown.remove(aKey)
    #expect(keys.flags(rightOption) == start)
}

@Test func keyedHoldBindingStartsOnKeyDownAndStopsOnKeyUp() {
    let f19: UInt16 = 80
    var keys = Harness(bindings: KeyStateMachine.Bindings(
        hold: KeySpec(modifiers: [], keyCode: f19),
        rawChord: KeySpec(modifiers: [.rightShift], keyCode: mKey),
        cancel: KeySpec(modifiers: [], keyCode: escapeKey)
    ))
    #expect(keys.down(f19) == KeyDecision(swallow: true, action: .start))
    #expect(keys.down(f19, isRepeat: true) == swallow)
    #expect(keys.up(f19) == KeyDecision(swallow: true, action: .stop))
    #expect(!keys.machine.isRecording)
}

@Test func controllerEndedRecordingKeepsSwallowedKeys() {
    var keys = Harness()
    #expect(keys.flags(rightOption) == start)
    #expect(keys.down(escapeKey, flags: rightOption) == KeyDecision(swallow: true, action: .cancel(.cancelKey)))
    #expect(keys.flags(rightOption) == pass)
    keys.machine.endRecording()
    #expect(keys.up(escapeKey, flags: rightOption) == swallow)
    #expect(keys.flags(0) == pass)
}

@Test func bindingsUpdateAppliesToTheNextHold() {
    var keys = Harness()
    var settings = DictationSettings()
    settings.holdKey = KeySpec(modifiers: [.rightCommand], keyCode: nil)
    keys.machine.update(bindings: KeyStateMachine.Bindings(settings))
    #expect(keys.flags(rightOption) == pass)
    #expect(keys.flags(0) == pass)
    #expect(keys.flags(0x100000 | 0x10, key: 54) == start)
}

@Test func physicalModifiersFromDeviceBits() {
    #expect(PhysicalModifiers(eventFlags: rightOption) == .rightOption)
    #expect(PhysicalModifiers(eventFlags: leftOption) == .leftOption)
    #expect(PhysicalModifiers(eventFlags: rightShift | leftCommand) == [.rightShift, .leftCommand])
    #expect(PhysicalModifiers(eventFlags: 0x40000 | 0x2000) == .rightControl)
    #expect(PhysicalModifiers(eventFlags: 0x800000) == .function)
    #expect(PhysicalModifiers(eventFlags: 0x80000) == .option)
    #expect(PhysicalModifiers(eventFlags: 0x100) == [])
}

@Test func holdIsDownReadsFlagsState() {
    let hold = KeySpec(modifiers: [.rightOption], keyCode: nil)
    #expect(KeyStateMachine.holdIsDown(hold, flags: rightOption) { _ in false })
    #expect(KeyStateMachine.holdIsDown(hold, flags: 0x80000) { _ in false })
    #expect(!KeyStateMachine.holdIsDown(hold, flags: leftOption) { _ in false })
    #expect(!KeyStateMachine.holdIsDown(hold, flags: 0) { _ in false })
    let keyed = KeySpec(modifiers: [], keyCode: 80)
    #expect(KeyStateMachine.holdIsDown(keyed, flags: 0) { $0 == 80 })
    #expect(!KeyStateMachine.holdIsDown(keyed, flags: 0) { _ in false })
}

@Test func keyCodeSetCoversAllWords() {
    var set = KeyCodeSet()
    #expect(set.isEmpty)
    for code: UInt16 in [0, 63, 64, 127, 128, 200, 255] { set.insert(code) }
    set.insert(300)
    for code: UInt16 in [0, 63, 64, 127, 128, 200, 255] { #expect(set.contains(code)) }
    #expect(!set.contains(300))
    #expect(!set.contains(1))
    set.filter { $0 < 128 }
    #expect(set.contains(127))
    #expect(!set.contains(128))
    #expect(!set.contains(255))
    set.remove(0)
    set.remove(63)
    set.remove(64)
    set.remove(127)
    #expect(set.isEmpty)
}
