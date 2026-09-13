import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import Core

/// One-off experiments that prove the risky mechanisms on this machine before
/// the real implementation. Launch through LaunchServices so macOS attributes
/// permissions to alauncher rather than to the terminal:
///
///     open -n -a ~/Applications/alauncher.app --args --spike perms [prompt]
///     … --spike tap
///     … --spike audio
///     … --spike type <chunk> <delay-ms>
///
/// Results are appended to ~/Library/Logs/alauncher/spike.log.
enum Spike {
    static let log = Log(name: "spike")

    static func run(_ arguments: [String]) {
        let name = arguments.first ?? "perms"
        log("=== spike \(arguments.joined(separator: " ")) pid=\(getpid())")
        DispatchQueue.global().async {
            switch name {
            case "perms": perms(prompt: arguments.contains("prompt"))
            case "tap": tap()
            case "audio": audio()
            case "type": typing(Array(arguments.dropFirst()))
            case "paste": paste()
            default: log("unknown spike \(name)")
            }
            log("=== done \(name)")
            log.flush()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Permissions

    static func perms(prompt: Bool) {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            let answered = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("microphone request answered: granted=\(granted)")
                answered.signal()
            }
            _ = answered.wait(timeout: .now() + 120)
        }
        let pasteboardAccess = DispatchQueue.main.sync { () -> Int in
            if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior.rawValue }
            return -1
        }
        log("""
            accessibility=\(AXIsProcessTrusted()) postEvents=\(CGPreflightPostEventAccess()) \
            listenEvents=\(CGPreflightListenEventAccess()) \
            microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized) \
            pasteboardAccess=\(pasteboardAccess) (0 default/ask, 1 ask, 2 allow, 3 deny)
            """)
    }

    // MARK: - Event tap

    static func tap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: spikeTapCallback, userInfo: nil
            ) else {
                log("tapCreate FAILED (accessibility=\(AXIsProcessTrusted()))")
                ready.signal()
                return
            }
            spikeTapPort = port
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "spike.tap"
        thread.start()
        ready.wait()
        guard spikeTapPort != nil else { return }

        // Shift stands in for Right Option: nothing else on this Mac (Handy,
        // Raycast) listens for Shift alone, the device bits work the same way, and
        // if the user types during the test they only get a capital letter.
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = spikeMagic
        func post(_ key: Int, down: Bool, modifier: Bool, flags: UInt64) -> UInt64 {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)!
            if modifier { event.type = .flagsChanged }
            event.flags = CGEventFlags(rawValue: flags)
            let at = mach_absolute_time()
            event.post(tap: .cghidEventTap)
            return at
        }
        let shift = CGEventFlags.maskShift.rawValue
        var posted: [(String, UInt64)] = []
        posted.append(("right shift down", post(kVK_RightShift, down: true, modifier: true, flags: shift | 0x4)))
        usleep(20_000)
        posted.append(("right shift up", post(kVK_RightShift, down: false, modifier: true, flags: 0)))
        usleep(20_000)
        posted.append(("left shift down", post(kVK_Shift, down: true, modifier: true, flags: shift | 0x2)))
        usleep(20_000)
        posted.append(("left shift up", post(kVK_Shift, down: false, modifier: true, flags: 0)))
        usleep(20_000)
        posted.append(("F19 down, swallowed", post(kVK_F19, down: true, modifier: false, flags: 0)))
        posted.append(("F19 up, swallowed", post(kVK_F19, down: false, modifier: false, flags: 0)))
        usleep(300_000)

        spikeTapLock.lock()
        let received = spikeTapEvents
        spikeTapLock.unlock()
        log("posted \(posted.count) synthetic events, tap saw \(received.count) of ours")
        for (index, (label, postedAt)) in posted.enumerated() {
            guard index < received.count else {
                log("  \(label): NOT SEEN")
                continue
            }
            let event = received[index]
            log(String(
                format: "  %@: type=%u keycode=%lld flags=0x%llx deviceBits=0x%llx latency=%.3f ms",
                label, event.type, event.keycode, event.flags, event.flags & 0xFFFF,
                milliseconds(event.at &- postedAt)
            ))
        }
    }

    // MARK: - Audio

    static func audio() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            log("microphone not authorized (status \(status.rawValue)); run the perms spike with prompt first")
            return
        }
        log("default input: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "?")")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log("input format: \(format)")

        // Even rounds do prepare+start at "key-down"; odd rounds prepare 300 ms
        // ahead, as if re-prepared right after the previous recording stopped.
        for round in 0..<8 {
            let preparedAhead = round % 2 == 1
            if preparedAhead {
                engine.prepare()
                usleep(300_000)
            }
            let lock = NSLock()
            var firstBufferAt: UInt64 = 0
            input.installTap(onBus: 0, bufferSize: 512, format: format) { _, _ in
                lock.lock()
                if firstBufferAt == 0 { firstBufferAt = mach_absolute_time() }
                lock.unlock()
            }
            let keyDown = mach_absolute_time()
            if !preparedAhead { engine.prepare() }
            let prepared = mach_absolute_time()
            do {
                try engine.start()
            } catch {
                log("engine.start failed: \(error)")
                return
            }
            let started = mach_absolute_time()
            var first: UInt64 = 0
            for _ in 0..<2000 {
                lock.lock()
                first = firstBufferAt
                lock.unlock()
                if first != 0 { break }
                usleep(1000)
            }
            log(String(
                format: "round %d preparedAhead=%@ prepare=%.1f ms start=%.1f ms keyDown→firstBuffer=%.1f ms",
                round, preparedAhead ? "yes" : "no", milliseconds(prepared - keyDown),
                milliseconds(started - prepared), first == 0 ? -1 : milliseconds(first - keyDown)
            ))
            engine.stop()
            input.removeTap(onBus: 0)
            usleep(700_000)
        }
    }

    // MARK: - Typing

    static let typingSample = "Typing test: the quick brown fox jumps over 13 lazy dogs; café ñ 🚀 \"quotes\" (parens) [brackets] {braces} <tags> $HOME ~/path `tick` #hash @at 100% end."

    /// Types `typingSample` into whatever text field has focus after a 3 s
    /// countdown, then reads the field back through Accessibility.
    static func typing(_ arguments: [String]) {
        let chunk = max(1, Int(arguments.first ?? "") ?? 1)
        let delayMicroseconds = UInt32((Double(arguments.dropFirst().first ?? "") ?? 0) * 1000)
        log("typing: focus an empty text field within 3 s (chunk=\(chunk) delay=\(delayMicroseconds) µs)")
        sleep(3)
        let app = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }
        let before = focusedValue()
        let start = mach_absolute_time()
        type(typingSample, chunk: chunk, delayMicroseconds: delayMicroseconds)
        let elapsed = milliseconds(mach_absolute_time() - start)
        // "enter" finishes a shell `read` in terminal tests, whose text can't be read back through AX.
        if arguments.contains("enter") {
            let source = CGEventSource(stateID: .hidSystemState)
            source?.userData = spikeMagic
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
        usleep(500_000)
        let after = focusedValue()
        let inserted = after.map { value in
            before.flatMap { value.hasPrefix($0) ? String(value.dropFirst($0.count)) : nil } ?? value
        }
        let match = inserted == typingSample
        log(String(format: "app=%@ typed %d characters in %.1f ms; readback %@", app, typingSample.count, elapsed,
                   after == nil ? "unavailable" : (match ? "matches" : "DIFFERS")))
        if let inserted, !match {
            log("  expected: \(typingSample)")
            log("  got:      \(inserted.suffix(300))")
        }
    }

    static func type(_ text: String, chunk: Int, delayMicroseconds: UInt32) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = spikeMagic
        var pending = ""
        func flush() {
            let units = Array(pending.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                event.flags = []
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cghidEventTap)
            }
            pending = ""
            if delayMicroseconds > 0 { usleep(delayMicroseconds) }
        }
        for character in text {
            // One event carries at most 20 UTF-16 units.
            if !pending.isEmpty, pending.count >= chunk || pending.utf16.count + character.utf16.count > 20 {
                flush()
            }
            pending.append(character)
        }
        if !pending.isEmpty { flush() }
    }

    // MARK: - Paste fallback

    static let pasteSample = "Paste test line one\nline two — café 🚀 end."
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    /// After a 3 s countdown: snapshots the pasteboard, writes `pasteSample` with
    /// the transient markers, posts Cmd+V into the focused field, restores the
    /// snapshot 250 ms later, then checks the field and the pasteboard. The
    /// user's clipboard content is compared, never logged.
    static func paste() {
        log("paste: focus an empty text field within 3 s")
        sleep(3)
        let pasteboard = NSPasteboard.general
        let (snapshot, originalText) = DispatchQueue.main.sync {
            (snapshotPasteboard(pasteboard, byteLimit: 16 << 20), pasteboard.string(forType: .string))
        }
        let ours = DispatchQueue.main.sync { () -> Int in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(pasteSample, forType: .string)
            item.setData(Data(), forType: transientType)
            item.setData(Data(), forType: autoGeneratedType)
            pasteboard.writeObjects([item])
            return pasteboard.changeCount
        }
        let before = focusedValue()
        postCommandV()
        usleep(250_000)
        let restored = DispatchQueue.main.sync { () -> Bool in
            guard pasteboard.changeCount == ours, let snapshot else { return false }
            pasteboard.clearContents()
            for item in snapshot { item.setData(Data(), forType: transientType) }
            return pasteboard.writeObjects(snapshot)
        }
        usleep(300_000)
        let after = focusedValue()
        let inserted = after.map { value in
            before.flatMap { value.hasPrefix($0) ? String(value.dropFirst($0.count)) : nil } ?? value
        }
        let clipboardBack = DispatchQueue.main.sync { pasteboard.string(forType: .string) == originalText }
        log("""
            paste: snapshot=\(snapshot.map { "\($0.count) item(s)" } ?? "skipped") \
            readback=\(after == nil ? "unavailable" : (inserted == pasteSample ? "matches" : "DIFFERS")) \
            restored=\(restored) clipboardBack=\(clipboardBack)
            """)
    }

    /// Fresh copies of every item and type, since retrieved items can't be written
    /// back. Nil when the data passes `byteLimit`.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard, byteLimit: Int) -> [NSPasteboardItem]? {
        var total = 0
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > byteLimit { return nil }
                copy.setData(data, forType: type)
            }
            copies.append(copy)
        }
        return copies
    }

    static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = spikeMagic
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)!
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    static func focusedValue() -> String? {
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func milliseconds(_ ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}

// MARK: - Tap callback state
// A C callback can't capture context, so the spike keeps its state in globals.
// Only our own synthetic events (tagged with `spikeMagic`) are recorded, never
// the user's real keystrokes.

private let spikeMagic: Int64 = 0x616C_6175_6E63
private var spikeTapPort: CFMachPort?
private let spikeTapLock = NSLock()
private var spikeTapEvents: [(type: UInt32, keycode: Int64, flags: UInt64, at: UInt64)] = []

private func spikeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let spikeTapPort { CGEvent.tapEnable(tap: spikeTapPort, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.eventSourceUserData) == spikeMagic else {
        return Unmanaged.passUnretained(event)
    }
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    spikeTapLock.lock()
    spikeTapEvents.append((type.rawValue, keycode, event.flags.rawValue, mach_absolute_time()))
    spikeTapLock.unlock()
    return keycode == Int64(kVK_F19) ? nil : Unmanaged.passUnretained(event)
}
