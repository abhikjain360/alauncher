import Core

/// Shared by the key monitor and the inserter.
public enum DictationConstants {
    /// `eventSourceUserData` on every event alauncher posts, so the key monitor can ignore them.
    public static let eventUserData: Int64 = 0x616C_6175_6E63
}

/// Physical modifier keys, read from the device-dependent bits of an event's flags (IOLLEvent.h).
public struct PhysicalModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let leftShift = PhysicalModifiers(rawValue: 1 << 0)
    public static let rightShift = PhysicalModifiers(rawValue: 1 << 1)
    public static let leftControl = PhysicalModifiers(rawValue: 1 << 2)
    public static let rightControl = PhysicalModifiers(rawValue: 1 << 3)
    public static let leftOption = PhysicalModifiers(rawValue: 1 << 4)
    public static let rightOption = PhysicalModifiers(rawValue: 1 << 5)
    public static let leftCommand = PhysicalModifiers(rawValue: 1 << 6)
    public static let rightCommand = PhysicalModifiers(rawValue: 1 << 7)
    public static let function = PhysicalModifiers(rawValue: 1 << 8)

    public static let shift: PhysicalModifiers = [.leftShift, .rightShift]
    public static let control: PhysicalModifiers = [.leftControl, .rightControl]
    public static let option: PhysicalModifiers = [.leftOption, .rightOption]
    public static let command: PhysicalModifiers = [.leftCommand, .rightCommand]
    static let families: [PhysicalModifiers] = [.shift, .control, .option, .command, .function]

    // CGEventFlags values: device bits, then the generic side-less masks.
    static let flagLeftShift: UInt64 = 0x2, flagRightShift: UInt64 = 0x4
    static let flagLeftControl: UInt64 = 0x1, flagRightControl: UInt64 = 0x2000
    static let flagLeftOption: UInt64 = 0x20, flagRightOption: UInt64 = 0x40
    static let flagLeftCommand: UInt64 = 0x8, flagRightCommand: UInt64 = 0x10
    static let maskShift: UInt64 = 0x20000, maskControl: UInt64 = 0x40000
    static let maskAlternate: UInt64 = 0x80000, maskCommand: UInt64 = 0x100000
    static let maskSecondaryFn: UInt64 = 0x800000

    /// A generic mask with neither device bit (some synthetic events) counts as both sides: that
    /// never matches a one-sided binding and cancels a recording, which is the safe reading.
    public init(eventFlags flags: UInt64) {
        var result: PhysicalModifiers = []
        let pairs: [(UInt64, UInt64, UInt64, PhysicalModifiers, PhysicalModifiers)] = [
            (Self.flagLeftShift, Self.flagRightShift, Self.maskShift, .leftShift, .rightShift),
            (Self.flagLeftControl, Self.flagRightControl, Self.maskControl, .leftControl, .rightControl),
            (Self.flagLeftOption, Self.flagRightOption, Self.maskAlternate, .leftOption, .rightOption),
            (Self.flagLeftCommand, Self.flagRightCommand, Self.maskCommand, .leftCommand, .rightCommand),
        ]
        for (left, right, generic, leftModifier, rightModifier) in pairs {
            let hasLeft = flags & left != 0
            let hasRight = flags & right != 0
            if hasLeft { result.insert(leftModifier) }
            if hasRight { result.insert(rightModifier) }
            if !hasLeft, !hasRight, flags & generic != 0 { result.formUnion([leftModifier, rightModifier]) }
        }
        if flags & Self.maskSecondaryFn != 0 { result.insert(.function) }
        self = result
    }
}

/// The modifier part of a `KeySpec`, compiled for matching against physical modifiers.
struct ModifierPattern: Equatable, Sendable {
    /// One-sided modifiers that must be held.
    var sided: PhysicalModifiers = []
    /// Families (both side bits) where either side, or both, satisfies the spec.
    var anySide: PhysicalModifiers = []

    init(_ modifiers: Set<KeySpec.Modifier>) {
        for modifier in modifiers {
            switch modifier {
            case .command: anySide.formUnion(.command)
            case .leftCommand: sided.insert(.leftCommand)
            case .rightCommand: sided.insert(.rightCommand)
            case .option: anySide.formUnion(.option)
            case .leftOption: sided.insert(.leftOption)
            case .rightOption: sided.insert(.rightOption)
            case .shift: anySide.formUnion(.shift)
            case .leftShift: sided.insert(.leftShift)
            case .rightShift: sided.insert(.rightShift)
            case .control: anySide.formUnion(.control)
            case .leftControl: sided.insert(.leftControl)
            case .rightControl: sided.insert(.rightControl)
            case .function: sided.insert(.function)
            }
        }
    }

    var allowed: PhysicalModifiers { sided.union(anySide) }

    /// Every required modifier is held (extra ones may be too).
    func isSatisfied(by held: PhysicalModifiers) -> Bool {
        guard held.isSuperset(of: sided) else { return false }
        for family in PhysicalModifiers.families where !family.isDisjoint(with: anySide) {
            if held.isDisjoint(with: family) { return false }
        }
        return true
    }

    /// Exactly the spec: everything required is held and nothing else.
    func matchesExactly(_ held: PhysicalModifiers) -> Bool {
        held.isSubset(of: allowed) && isSatisfied(by: held)
    }
}

/// A fixed 256-bit set of virtual key codes, so the tap callback never allocates.
struct KeyCodeSet: Equatable, Sendable {
    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    static func == (lhs: KeyCodeSet, rhs: KeyCodeSet) -> Bool {
        lhs.words.0 == rhs.words.0 && lhs.words.1 == rhs.words.1
            && lhs.words.2 == rhs.words.2 && lhs.words.3 == rhs.words.3
    }

    var isEmpty: Bool { words.0 | words.1 | words.2 | words.3 == 0 }

    func contains(_ code: UInt16) -> Bool {
        guard code < 256 else { return false }
        return word(Int(code) >> 6) & (1 << UInt64(code & 63)) != 0
    }

    mutating func insert(_ code: UInt16) {
        guard code < 256 else { return }
        setWord(Int(code) >> 6, word(Int(code) >> 6) | (1 << UInt64(code & 63)))
    }

    mutating func remove(_ code: UInt16) {
        guard code < 256 else { return }
        setWord(Int(code) >> 6, word(Int(code) >> 6) & ~(1 << UInt64(code & 63)))
    }

    mutating func removeAll() { words = (0, 0, 0, 0) }

    /// Drops every code for which `keep` returns false.
    mutating func filter(_ keep: (UInt16) -> Bool) {
        for index in 0..<4 {
            var remaining = word(index)
            while remaining != 0 {
                let bit = UInt64(remaining.trailingZeroBitCount)
                remaining &= remaining - 1
                let code = UInt16(index * 64) + UInt16(bit)
                if !keep(code) { remove(code) }
            }
        }
    }

    private func word(_ index: Int) -> UInt64 {
        switch index {
        case 0: return words.0
        case 1: return words.1
        case 2: return words.2
        default: return words.3
        }
    }

    private mutating func setWord(_ index: Int, _ value: UInt64) {
        switch index {
        case 0: words.0 = value
        case 1: words.1 = value
        case 2: words.2 = value
        default: words.3 = value
        }
    }
}

/// One event as the tap sees it.
public struct KeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyDown, keyUp, flagsChanged, mouseDown
        /// The system disabled the tap (timeout or user input).
        case tapDisabled
    }

    public var kind: Kind
    public var keyCode: UInt16
    /// `CGEventFlags.rawValue`, including the device-dependent bits.
    public var flags: UInt64
    public var isRepeat: Bool
    /// `eventSourceUserData`.
    public var userData: Int64

    public init(kind: Kind, keyCode: UInt16 = 0, flags: UInt64 = 0, isRepeat: Bool = false, userData: Int64 = 0) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.userData = userData
    }
}

public enum KeyCancelReason: String, Equatable, Sendable {
    case cancelKey, otherKey, otherModifier, mouse, tapDisabled
}

/// What the controller should do. Posted to the main queue by the monitor.
public enum KeyAction: Equatable, Sendable {
    case start
    case switchToRaw
    /// The hold key was released: finish the recording.
    case stop
    /// Cancel the recording, or (for `.cancelKey` while busy) the processing.
    case cancel(KeyCancelReason)
}

public struct KeyDecision: Equatable, Sendable {
    /// Return nil from the tap so no app sees the event.
    public var swallow: Bool
    public var action: KeyAction?

    public init(swallow: Bool = false, action: KeyAction? = nil) {
        self.swallow = swallow
        self.action = action
    }

    static let pass = KeyDecision()
}

/// The dictation key rules, as a pure value type. It lives on the tap thread and is only ever
/// touched there; each call does a few comparisons and bit operations and never allocates.
public struct KeyStateMachine: Sendable {
    public struct Bindings: Equatable, Sendable {
        public var hold: KeySpec
        public var rawChord: KeySpec
        public var cancel: KeySpec

        public init(hold: KeySpec, rawChord: KeySpec, cancel: KeySpec) {
            self.hold = hold
            self.rawChord = rawChord
            self.cancel = cancel
        }

        public init(_ settings: DictationSettings) {
            self.init(hold: settings.holdKey, rawChord: settings.rawChord, cancel: settings.cancelKey)
        }
    }

    public private(set) var bindings: Bindings
    public private(set) var isRecording = false
    public private(set) var isRaw = false

    private var hold: ModifierPattern
    private var raw: ModifierPattern
    private var cancel: ModifierPattern
    private var held: PhysicalModifiers = []
    /// Non-modifier keys currently down.
    private var down = KeyCodeSet()
    /// Keys whose down we swallowed: their repeats and their up are swallowed too.
    private var swallowed = KeyCodeSet()

    public init(bindings: Bindings) {
        self.bindings = bindings
        hold = ModifierPattern(bindings.hold.modifiers)
        raw = ModifierPattern(bindings.rawChord.modifiers)
        cancel = ModifierPattern(bindings.cancel.modifiers)
    }

    public mutating func update(bindings newBindings: Bindings) {
        guard newBindings != bindings else { return }
        bindings = newBindings
        hold = ModifierPattern(newBindings.hold.modifiers)
        raw = ModifierPattern(newBindings.rawChord.modifiers)
        cancel = ModifierPattern(newBindings.cancel.modifiers)
    }

    /// The controller ended the recording on its own (max duration, missed release, sleep).
    /// Swallowed keys are kept so their key-ups still don't leak.
    public mutating func endRecording() {
        isRecording = false
        isRaw = false
    }

    /// - Parameters:
    ///   - busy: the controller is transcribing or post-processing.
    ///   - isKeyDown: asks the system whether a key is still down; consulted only when a start is
    ///     blocked by keys we think are down, since a key-up can be missed (secure input).
    public mutating func handle(
        _ event: KeyEvent, busy: Bool, isKeyDown: (UInt16) -> Bool = { _ in true }
    ) -> KeyDecision {
        if event.kind == .tapDisabled {
            let wasRecording = isRecording
            isRecording = false
            isRaw = false
            held = []
            down.removeAll()
            swallowed.removeAll()
            return KeyDecision(action: wasRecording ? .cancel(.tapDisabled) : nil)
        }
        if event.userData == DictationConstants.eventUserData { return .pass }

        switch event.kind {
        case .flagsChanged: return flagsChanged(PhysicalModifiers(eventFlags: event.flags), isKeyDown: isKeyDown)
        case .keyDown: return keyDown(event, busy: busy, isKeyDown: isKeyDown)
        case .keyUp: return keyUp(event)
        case .mouseDown:
            guard isRecording else { return .pass }
            endRecording()
            return KeyDecision(action: .cancel(.mouse))
        case .tapDisabled: return .pass
        }
    }

    // Modifier events always pass through.
    private mutating func flagsChanged(_ now: PhysicalModifiers, isKeyDown: (UInt16) -> Bool) -> KeyDecision {
        let previous = held
        held = now

        if isRecording {
            if bindings.hold.keyCode == nil, !hold.isSatisfied(by: now) {
                endRecording()
                return KeyDecision(action: .stop)
            }
            if !now.isSubset(of: raw.allowed.union(hold.allowed)) {
                endRecording()
                return KeyDecision(action: .cancel(.otherModifier))
            }
            return .pass
        }

        // Start on the press that completes the hold binding, never on a release that happens to
        // leave it (e.g. letting go of Left Option while holding both).
        let pressedSomething = !now.subtracting(previous).isEmpty
        guard bindings.hold.keyCode == nil, pressedSomething, hold.matchesExactly(now),
              noKeysDown(isKeyDown: isKeyDown) else { return .pass }
        isRecording = true
        isRaw = false
        return KeyDecision(action: .start)
    }

    private mutating func keyDown(_ event: KeyEvent, busy: Bool, isKeyDown: (UInt16) -> Bool) -> KeyDecision {
        let code = event.keyCode
        let modifiers = PhysicalModifiers(eventFlags: event.flags)
        if swallowed.contains(code) {
            if event.isRepeat {
                down.insert(code)
                return KeyDecision(swallow: true)
            }
            // A fresh press of a remembered key: its key-up was missed (secure input hides it).
            // Forget it and treat this as a new press.
            swallowed.remove(code)
        }

        if isRecording {
            down.insert(code)
            if code == bindings.rawChord.keyCode, raw.matchesExactly(modifiers) {
                swallowed.insert(code)
                guard !isRaw else { return KeyDecision(swallow: true) }
                isRaw = true
                return KeyDecision(swallow: true, action: .switchToRaw)
            }
            if code == bindings.cancel.keyCode, cancel.isSatisfied(by: modifiers) {
                swallowed.insert(code)
                endRecording()
                return KeyDecision(swallow: true, action: .cancel(.cancelKey))
            }
            // Option+letter typing keeps working: cancel silently and let the key through.
            endRecording()
            return KeyDecision(action: .cancel(.otherKey))
        }

        if let holdCode = bindings.hold.keyCode, code == holdCode, !event.isRepeat,
           hold.matchesExactly(modifiers), noKeysDown(isKeyDown: isKeyDown) {
            down.insert(code)
            swallowed.insert(code)
            isRecording = true
            isRaw = false
            return KeyDecision(swallow: true, action: .start)
        }
        down.insert(code)
        if busy, code == bindings.cancel.keyCode, cancel.matchesExactly(modifiers), !event.isRepeat {
            swallowed.insert(code)
            return KeyDecision(swallow: true, action: .cancel(.cancelKey))
        }
        return .pass
    }

    private mutating func keyUp(_ event: KeyEvent) -> KeyDecision {
        let code = event.keyCode
        down.remove(code)
        var decision = KeyDecision.pass
        if isRecording, let holdCode = bindings.hold.keyCode, code == holdCode {
            endRecording()
            decision.action = .stop
        }
        if swallowed.contains(code) {
            swallowed.remove(code)
            decision.swallow = true
        }
        return decision
    }

    /// True when no non-modifier key is down. Entries whose key-up we missed are dropped after
    /// asking the system.
    private mutating func noKeysDown(isKeyDown: (UInt16) -> Bool) -> Bool {
        guard !down.isEmpty else { return true }
        down.filter(isKeyDown)
        return down.isEmpty
    }
}
