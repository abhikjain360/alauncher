import Carbon.HIToolbox
import Core
import Foundation

/// `KeySpec` → the key code and modifier mask for Carbon's `RegisterEventHotKey`.
enum HotKeyMapping {
    struct CarbonKey: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Carbon can't tell left from right, so `right_option` can't be honored.
        case sideSpecificModifier(KeySpec.Modifier)
        /// Carbon hotkeys have no fn modifier.
        case functionModifier
        /// A modifier-only spec such as `right_option`.
        case missingKey

        var description: String {
            switch self {
            case .sideSpecificModifier(let modifier):
                let name = KeySpec(modifiers: [modifier], keyCode: nil).description
                return "launcher.hotkey: \(name) can't be used; the launcher hotkey can't tell left from right, so use \(HotKeyMapping.sidelessName(for: modifier))"
            case .functionModifier:
                return "launcher.hotkey: fn can't be part of the launcher hotkey"
            case .missingKey:
                return "launcher.hotkey: needs a key, not only modifiers"
            }
        }
    }

    static func carbonKey(for spec: KeySpec) -> Result<CarbonKey, Failure> {
        var modifiers: UInt32 = 0
        for modifier in KeySpec.Modifier.allCases where spec.modifiers.contains(modifier) {
            switch modifier {
            case .command: modifiers |= UInt32(cmdKey)
            case .option: modifiers |= UInt32(optionKey)
            case .shift: modifiers |= UInt32(shiftKey)
            case .control: modifiers |= UInt32(controlKey)
            case .function: return .failure(.functionModifier)
            case .leftCommand, .rightCommand, .leftOption, .rightOption,
                 .leftShift, .rightShift, .leftControl, .rightControl:
                return .failure(.sideSpecificModifier(modifier))
            }
        }
        guard let keyCode = spec.keyCode else { return .failure(.missingKey) }
        return .success(CarbonKey(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    static func sidelessName(for modifier: KeySpec.Modifier) -> String {
        switch modifier {
        case .command, .leftCommand, .rightCommand: return "cmd"
        case .option, .leftOption, .rightOption: return "option"
        case .shift, .leftShift, .rightShift: return "shift"
        case .control, .leftControl, .rightControl: return "ctrl"
        case .function: return "fn"
        }
    }
}

/// 'alnc'
private let hotKeySignature: OSType = 0x616C_6E63

/// The launcher's global hotkey, through Carbon `RegisterEventHotKey`. Carbon
/// delivers the events on the main thread.
@MainActor
final class HotKey {
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false
    private(set) var registeredSpec: KeySpec?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// Registers `spec`, replacing any earlier registration. Nil on success, otherwise
    /// a message for the pill.
    func register(_ spec: KeySpec) -> String? {
        if spec == registeredSpec, hotKeyRef != nil { return nil }
        unregister()

        let key: HotKeyMapping.CarbonKey
        switch HotKeyMapping.carbonKey(for: spec) {
        case .success(let carbonKey): key = carbonKey
        case .failure(let failure): return failure.description
        }
        guard installHandler() else { return "launcher hotkey: couldn't install the event handler" }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.keyCode,
            key.modifiers,
            EventHotKeyID(signature: hotKeySignature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return "launcher hotkey \(spec) is taken"
        }
        hotKeyRef = ref
        registeredSpec = spec
        return nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredSpec = nil
        isDown = false
    }

    /// Unregisters and removes the Carbon event handler.
    func invalidate() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
    }

    /// When the last press, or key repeat, arrived.
    private var lastPress: TimeInterval = 0

    /// Pressed and released are both watched, so holding the keys doesn't toggle the
    /// panel over and over. A release that never arrives (the Mac locked or slept
    /// mid-press) can't wedge the hotkey: a press 1.5 s after the last one is new.
    func handle(pressed: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard pressed else {
            isDown = false
            return
        }
        defer { lastPress = now }
        if isDown, now - lastPress < 1.5 { return }
        isDown = true
        action()
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                if Thread.isMainThread {
                    MainActor.assumeIsolated { hotKey.handle(pressed: pressed) }
                } else {
                    DispatchQueue.main.async { hotKey.handle(pressed: pressed) }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }
}
