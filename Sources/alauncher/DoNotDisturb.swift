import AppKit
import ApplicationServices
import Core
import Overlay

@MainActor
enum DoNotDisturb {
    private static let controlCenterBundleID = "com.apple.controlcenter"
    private static let menuItemID = "com.apple.menuextra.controlcenter"
    private static let focusModuleID = "controlcenter-focus-modes"
    private static let doNotDisturbRowID = "focus-mode-activity-com.apple.donotdisturb.mode.default"
    private static var isToggling = false

    static func toggle() {
        guard !isToggling else { return }
        guard AXIsProcessTrusted() else {
            OverlayPill.shared.flash("Do Not Disturb needs Accessibility", isError: true)
            return
        }
        isToggling = true
        Task {
            defer { isToggling = false }
            do {
                let isOn = try await pressDoNotDisturb()
                OverlayPill.shared.flash(isOn ? "Do Not Disturb on" : "Do Not Disturb off", duration: 1.2)
            } catch {
                Log.main("do not disturb: \(error)")
                OverlayPill.shared.flash("couldn't toggle Do Not Disturb", isError: true)
            }
        }
    }

    private static func pressDoNotDisturb() async throws -> Bool {
        guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: controlCenterBundleID).first else {
            throw ToggleError.noControlCenter
        }
        let app = AXUIElementCreateApplication(controlCenter.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let menuBar = uiElement(app, "AXExtrasMenuBar"),
              let menuItem = children(menuBar).first(where: { identifier($0) == menuItemID }) else {
            throw ToggleError.noMenuItem
        }
        if windows(app).isEmpty { press(menuItem) }
        do {
            guard var found = await firstElement([doNotDisturbRowID, focusModuleID], in: app, timeout: 2) else {
                throw ToggleError.noFocusModule
            }
            if found.id == focusModuleID {
                press(found.element)
                guard let row = await firstElement([doNotDisturbRowID], in: app, timeout: 1) else {
                    throw ToggleError.noDoNotDisturbRow
                }
                found = row
            }
            let wasOn = (value(found.element, kAXValueAttribute) as? NSNumber)?.intValue == 1
            press(found.element)
            await close(app, menuItem: menuItem)
            return !wasOn
        } catch {
            await close(app, menuItem: menuItem)
            throw error
        }
    }

    private static func close(_ app: AXUIElement, menuItem: AXUIElement) async {
        for _ in 0..<3 {
            guard !windows(app).isEmpty else { return }
            let showsFocusList = find(focusModuleID, in: app) == nil
            press(menuItem)
            await wait(timeout: 0.5) {
                windows(app).isEmpty || (showsFocusList && find(focusModuleID, in: app) != nil)
            }
        }
    }

    private static func firstElement(
        _ ids: [String], in app: AXUIElement, timeout: TimeInterval
    ) async -> (id: String, element: AXUIElement)? {
        var found: (id: String, element: AXUIElement)?
        await wait(timeout: timeout) {
            found = ids.lazy.compactMap { id in find(id, in: app).map { (id: id, element: $0) } }.first
            return found != nil
        }
        return found
    }

    private static func wait(timeout: TimeInterval, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func find(_ id: String, in app: AXUIElement) -> AXUIElement? {
        windows(app).lazy.compactMap { find(id, under: $0, depth: 0) }.first
    }

    private static func find(_ id: String, under element: AXUIElement, depth: Int) -> AXUIElement? {
        if identifier(element) == id { return element }
        guard depth < 3 else { return nil }
        return children(element).lazy.compactMap { find(id, under: $0, depth: depth + 1) }.first
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        value(element, kAXIdentifierAttribute) as? String
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func uiElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private enum ToggleError: Error, CustomStringConvertible {
        case noControlCenter
        case noMenuItem
        case noFocusModule
        case noDoNotDisturbRow

        var description: String {
            switch self {
            case .noControlCenter: return "Control Center isn't running"
            case .noMenuItem: return "no Control Center menu bar item"
            case .noFocusModule: return "no Focus control in Control Center"
            case .noDoNotDisturbRow: return "no Do Not Disturb row in Focus"
            }
        }
    }
}
