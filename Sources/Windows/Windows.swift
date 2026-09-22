import ApplicationServices
import AppKit
import Core
import Foundation
import Overlay

/// Applies Raycast-style window commands to the focused window of the frontmost app.
@MainActor
public enum Windows {
    private static let restoreStore = RestoreStore()
    private static let log = Log.main
    private static let fullScreenAttribute = "AXFullScreen" as CFString
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    /// Accessibility calls block the caller; a hung app must not hold the main thread for
    /// the default six seconds.
    private static let messagingTimeout: Float = 1

    public static func perform(_ command: WindowCommand) {
        guard AXIsProcessTrusted() else {
            fail("window commands need Accessibility", logMessage: "accessibility is not trusted")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            fail("no window to move", logMessage: "no frontmost application")
            return
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let window = focusedWindow(in: application) else {
            fail("no window to move", logMessage: "no focused window")
            return
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        let box = AXElementBox(window)
        let fullScreen = boolAttribute(window, name: fullScreenAttribute) ?? false
        if fullScreen && command != .toggleFullscreen {
            fail("window is full screen", logMessage: "focused window is full screen")
            return
        }

        if command == .restore {
            guard let remembered = restoreStore.original(for: box) else {
                fail("nothing to restore", logMessage: "restore requested without a remembered frame")
                return
            }
            // Displays may have changed since, so keep the frame on a screen that exists now.
            let screens = displayFrames()
            var target = remembered
            if let index = WindowGeometry.screenIndex(containing: remembered, in: screens.map(\.frame)) {
                target = WindowGeometry.fitted(remembered, inside: screens[index].visibleFrame)
            }
            var moved = false
            withEnhancedUserInterfaceDisabled(application) {
                moved = move(target, window: window)
            }
            // A failed move keeps the memory, so Restore can be tried again.
            if moved { _ = restoreStore.take(box) }
            return
        }

        if command == .toggleFullscreen {
            guard isAttributeSettable(window, name: fullScreenAttribute) else {
                fail("app doesn't support fullscreen", logMessage: "full-screen attribute is not settable")
                return
            }
            let value = (fullScreen ? kCFBooleanFalse : kCFBooleanTrue)!
            guard AXUIElementSetAttributeValue(window, fullScreenAttribute, value) == .success else {
                fail("couldn't toggle fullscreen", logMessage: "could not set full-screen attribute")
                return
            }
            return
        }

        let displayFrames = displayFrames()
        guard !displayFrames.isEmpty else {
            fail("couldn't find a display", logMessage: "no NSScreen available")
            return
        }
        if (command == .nextDisplay || command == .previousDisplay) && displayFrames.count == 1 {
            OverlayPill.shared.flash("only one display")
            return
        }
        guard let currentFrame = frame(of: window) else {
            fail("couldn't read window frame", logMessage: "could not read focused window frame")
            return
        }

        let sourceIndex = WindowGeometry.screenIndex(
            containing: currentFrame,
            in: displayFrames.map(\.frame),
            primaryIndex: 0
        ) ?? 0
        let targetFrame: CGRect
        if command == .nextDisplay || command == .previousDisplay {
            let ordered = displayFrames.enumerated().sorted(by: screenComesFirst)
            let sourceOrder = ordered.firstIndex(where: { $0.offset == sourceIndex }) ?? 0
            let change = command == .nextDisplay ? 1 : -1
            let targetOrder = (sourceOrder + change + ordered.count) % ordered.count
            let targetIndex = ordered[targetOrder].offset
            targetFrame = WindowGeometry.frame(
                for: command,
                from: displayFrames[sourceIndex].visibleFrame,
                to: displayFrames[targetIndex].visibleFrame,
                window: currentFrame
            )
        } else {
            targetFrame = WindowGeometry.frame(for: command, in: displayFrames[sourceIndex].visibleFrame, window: currentFrame)
        }

        restoreStore.willMove(box, from: currentFrame)
        withEnhancedUserInterfaceDisabled(application) {
            move(targetFrame, window: window)
        }
        // Apps may not land exactly on the target, and some apply it late, so remember both.
        restoreStore.didMove(box, to: frame(of: window) ?? targetFrame, requested: targetFrame)
    }

    private struct DisplayFrame {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    private static func displayFrames() -> [DisplayFrame] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.map { screen in
            DisplayFrame(
                frame: WindowGeometry.accessibilityRect(screen.frame, primaryFrame: primary.frame),
                visibleFrame: WindowGeometry.accessibilityRect(screen.visibleFrame, primaryFrame: primary.frame)
            )
        }
    }

    private static func screenComesFirst(_ lhs: (offset: Int, element: DisplayFrame), _ rhs: (offset: Int, element: DisplayFrame)) -> Bool {
        if lhs.element.frame.minX != rhs.element.frame.minX {
            return lhs.element.frame.minX < rhs.element.frame.minX
        }
        if lhs.element.frame.minY != rhs.element.frame.minY {
            return lhs.element.frame.minY < rhs.element.frame.minY
        }
        return lhs.offset < rhs.offset
    }

    /// The focused window, or the main window for apps that don't report one.
    private static func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(application, name as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { continue }
            return (value as! AXUIElement)
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = pointValue(of: window, name: kAXPositionAttribute as CFString),
              let size = sizeValue(of: window, name: kAXSizeAttribute as CFString)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func pointValue(of element: AXUIElement, name: CFString) -> CGPoint? {
        guard let value = axValue(of: element, name: name, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(of element: AXUIElement, name: CFString) -> CGSize? {
        guard let value = axValue(of: element, name: name, type: .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(of element: AXUIElement, name: CFString, type: AXValueType) -> AXValue? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    private static func boolAttribute(_ element: AXUIElement, name: CFString) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
    }

    private static func isAttributeSettable(_ element: AXUIElement, name: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name, &settable) == .success && settable.boolValue
    }

    @discardableResult
    private static func move(_ frame: CGRect, window: AXUIElement) -> Bool {
        let sizeIsSettable = isAttributeSettable(window, name: kAXSizeAttribute as CFString)
        var success = true
        if sizeIsSettable {
            success = setSize(frame.size, on: window) && success
            success = setPosition(frame.origin, on: window) && success
            success = setSize(frame.size, on: window) && success
        } else {
            success = setPosition(frame.origin, on: window)
        }
        guard !success else { return true }
        fail("couldn't move window", logMessage: "one or more Accessibility frame writes failed")
        return false
    }

    private static func setPosition(_ position: CGPoint, on window: AXUIElement) -> Bool {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func setSize(_ size: CGSize, on window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    private static func withEnhancedUserInterfaceDisabled(_ application: AXUIElement, _ body: () -> Void) {
        guard boolAttribute(application, name: enhancedUserInterfaceAttribute) == true else {
            body()
            return
        }
        _ = AXUIElementSetAttributeValue(application, enhancedUserInterfaceAttribute, kCFBooleanFalse)
        defer {
            _ = AXUIElementSetAttributeValue(application, enhancedUserInterfaceAttribute, kCFBooleanTrue)
        }
        body()
    }

    private static func fail(_ message: String, logMessage: String) {
        log("window command failed: \(logMessage)")
        OverlayPill.shared.flash(message, isError: true)
    }
}
