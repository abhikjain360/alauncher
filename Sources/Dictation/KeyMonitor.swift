import Core
import CoreGraphics
import Foundation
import os
import Synchronization

/// A Bool the tap thread can read without taking a contended lock.
public final class BusyFlag: Sendable {
    private let storage: any FlagStorage

    public init() {
        if #available(macOS 15.0, *) {
            storage = AtomicFlagStorage()
        } else {
            storage = LockedFlagStorage()
        }
    }

    public var value: Bool {
        get { storage.load() }
        set { storage.store(newValue) }
    }
}

private protocol FlagStorage: AnyObject, Sendable {
    func load() -> Bool
    func store(_ value: Bool)
}

@available(macOS 15.0, *)
private final class AtomicFlagStorage: FlagStorage {
    private let flag = Atomic<Bool>(false)
    func load() -> Bool { flag.load(ordering: .acquiring) }
    func store(_ value: Bool) { flag.store(value, ordering: .releasing) }
}

/// macOS 14 only; this Mac takes the atomic path.
private final class LockedFlagStorage: FlagStorage {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func load() -> Bool { lock.withLock { $0 } }
    func store(_ value: Bool) { lock.withLock { $0 = value } }
}

/// The dictation keys: an active session-level CGEventTap on a dedicated thread with its own
/// run loop.
///
/// The callback only feeds `KeyStateMachine` (pure, allocation-free), returns the event or nil,
/// and posts any action to the main queue asynchronously. It never waits on a lock, an actor,
/// audio, logging or AppKit. The machine is touched only on the tap thread: configuration
/// changes are handed over with `CFRunLoopPerformBlock`.
final class KeyMonitor: @unchecked Sendable {
    private let busy: BusyFlag
    private let onAction: @MainActor @Sendable (KeyAction) -> Void

    // Tap thread only.
    private var machine: KeyStateMachine
    private var port: CFMachPort?

    // Written on the tap thread before `start()` returns, then read on the main thread.
    private var runLoop: CFRunLoop?
    private var tapCreated = false

    init(bindings: KeyStateMachine.Bindings, busy: BusyFlag, onAction: @escaping @MainActor @Sendable (KeyAction) -> Void) {
        machine = KeyStateMachine(bindings: bindings)
        self.busy = busy
        self.onAction = onAction
    }

    /// Creates the tap and its thread. False when the tap can't be created (Accessibility isn't
    /// granted to this signed build).
    func start() -> Bool {
        if runLoop != nil { return true }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in runTap(ready: ready) }
        thread.name = "alauncher.key-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return tapCreated
    }

    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        tapCreated = false
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
    }

    func update(bindings: KeyStateMachine.Bindings) {
        onTapThread { $0.machine.update(bindings: bindings) }
    }

    /// Tells the machine the controller ended the recording itself.
    func endRecording() {
        onTapThread { $0.machine.endRecording() }
    }

    private func onTapThread(_ body: @escaping @Sendable (KeyMonitor) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in body(self) }
        CFRunLoopWakeUp(runLoop)
    }

    private func runTap(ready: DispatchSemaphore) {
        machine = KeyStateMachine(bindings: machine.bindings)
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyMonitorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let loop = CFRunLoopGetCurrent()
        self.port = port
        runLoop = loop
        tapCreated = true
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        ready.signal()

        CFRunLoopRun()

        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(port)
        self.port = nil
    }

    /// Called on the tap thread for every event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let kind: KeyEvent.Kind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let decision = machine.handle(KeyEvent(kind: .tapDisabled), busy: false)
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            post(decision.action)
            return Unmanaged.passUnretained(event)
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        default: return Unmanaged.passUnretained(event)
        }

        let keyEvent = KeyEvent(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            userData: event.getIntegerValueField(.eventSourceUserData)
        )
        let decision = machine.handle(keyEvent, busy: busy.value) { code in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        post(decision.action)
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func post(_ action: KeyAction?) {
        guard let action else { return }
        let onAction = self.onAction
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onAction(action) }
        }
    }
}

private func keyMonitorCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

extension KeyStateMachine {
    /// Whether the hold binding's keys are physically down in `flags` (from
    /// `CGEventSource.flagsState`). Used to catch a release the tap never saw.
    static func holdIsDown(_ hold: KeySpec, flags: UInt64, keyIsDown: (UInt16) -> Bool) -> Bool {
        let modifiersDown = ModifierPattern(hold.modifiers).isSatisfied(by: PhysicalModifiers(eventFlags: flags))
        guard let code = hold.keyCode else { return modifiersDown }
        return modifiersDown && keyIsDown(code)
    }
}
