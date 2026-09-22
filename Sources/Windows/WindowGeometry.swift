import Foundation

/// Pure frame calculations for window commands. Coordinates are global Accessibility
/// coordinates: the primary display starts at the top left and y grows downwards.
public enum WindowGeometry {
    /// Calculates a command's frame inside `screen`.
    public static func frame(for command: WindowCommand, in screen: CGRect, window: CGRect) -> CGRect {
        let result: CGRect
        switch command {
        case .leftHalf:
            result = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .rightHalf:
            result = CGRect(x: screen.minX + screen.width / 2, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .topHalf:
            result = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height / 2)
        case .bottomHalf:
            result = CGRect(x: screen.minX, y: screen.minY + screen.height / 2, width: screen.width, height: screen.height / 2)
        case .centerHalf:
            result = CGRect(x: screen.minX + screen.width / 4, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .topLeft:
            result = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .topRight:
            result = CGRect(x: screen.minX + screen.width / 2, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .bottomLeft:
            result = CGRect(x: screen.minX, y: screen.minY + screen.height / 2, width: screen.width / 2, height: screen.height / 2)
        case .bottomRight:
            result = CGRect(x: screen.minX + screen.width / 2, y: screen.minY + screen.height / 2, width: screen.width / 2, height: screen.height / 2)
        case .firstThird:
            result = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 3, height: screen.height)
        case .centerThird:
            result = CGRect(x: screen.minX + screen.width / 3, y: screen.minY, width: screen.width / 3, height: screen.height)
        case .lastThird:
            result = CGRect(x: screen.minX + 2 * screen.width / 3, y: screen.minY, width: screen.width / 3, height: screen.height)
        case .firstTwoThirds:
            result = CGRect(x: screen.minX, y: screen.minY, width: 2 * screen.width / 3, height: screen.height)
        case .lastTwoThirds:
            result = CGRect(x: screen.minX + screen.width / 3, y: screen.minY, width: 2 * screen.width / 3, height: screen.height)
        case .maximize:
            result = screen
        case .almostMaximize:
            result = CGRect(
                x: screen.minX + screen.width * 0.05,
                y: screen.minY + screen.height * 0.05,
                width: screen.width * 0.9,
                height: screen.height * 0.9
            )
        case .maximizeHeight:
            result = CGRect(x: window.minX, y: screen.minY, width: window.width, height: screen.height)
        case .maximizeWidth:
            result = CGRect(x: screen.minX, y: window.minY, width: screen.width, height: window.height)
        case .center:
            let size = clampedSize(of: window, inside: screen)
            result = CGRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .makeLarger:
            result = resized(window, byWidth: screen.width / 10, byHeight: screen.height / 10, inside: screen)
        case .makeSmaller:
            let width = max(screen.width / 5, window.width - screen.width / 10)
            let height = max(screen.height / 5, window.height - screen.height / 10)
            result = resized(window, width: width, height: height, inside: screen)
        case .moveLeft:
            let clamped = clamped(window, inside: screen)
            result = CGRect(x: screen.minX, y: clamped.minY, width: clamped.width, height: clamped.height)
        case .moveRight:
            let clamped = clamped(window, inside: screen)
            result = CGRect(x: screen.maxX - clamped.width, y: clamped.minY, width: clamped.width, height: clamped.height)
        case .moveUp:
            let clamped = clamped(window, inside: screen)
            result = CGRect(x: clamped.minX, y: screen.minY, width: clamped.width, height: clamped.height)
        case .moveDown:
            let clamped = clamped(window, inside: screen)
            result = CGRect(x: clamped.minX, y: screen.maxY - clamped.height, width: clamped.width, height: clamped.height)
        case .nextDisplay, .previousDisplay, .restore, .toggleFullscreen:
            result = window
        }
        return finish(result, inside: screen)
    }

    /// Maps a window proportionally between visible frames. This is used for the
    /// next- and previous-display commands.
    public static func frame(
        for command: WindowCommand,
        from sourceScreen: CGRect,
        to targetScreen: CGRect,
        window: CGRect
    ) -> CGRect {
        guard command == .nextDisplay || command == .previousDisplay,
              sourceScreen.width > 0, sourceScreen.height > 0
        else {
            return frame(for: command, in: targetScreen, window: window)
        }

        let mapped = CGRect(
            x: targetScreen.minX + (window.minX - sourceScreen.minX) * targetScreen.width / sourceScreen.width,
            y: targetScreen.minY + (window.minY - sourceScreen.minY) * targetScreen.height / sourceScreen.height,
            width: window.width * targetScreen.width / sourceScreen.width,
            height: window.height * targetScreen.height / sourceScreen.height
        )
        return finish(mapped, inside: targetScreen)
    }

    /// Rounds a frame to whole points and keeps it inside `screen`, as every command does.
    public static func fitted(_ rect: CGRect, inside screen: CGRect) -> CGRect {
        finish(rect, inside: screen)
    }

    /// Converts an AppKit rectangle to Accessibility coordinates using the primary
    /// display's height. The primary display is expected to have origin (0, 0).
    public static func accessibilityRect(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Finds the display containing the window's center, falling back to the display
    /// with the largest intersection and then to `primaryIndex`.
    public static func screenIndex(
        containing window: CGRect,
        in screens: [CGRect],
        primaryIndex: Int = 0
    ) -> Int? {
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        if let index = screens.firstIndex(where: { $0.contains(center) }) {
            return index
        }

        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let intersection = screen.intersection(window)
            let area = intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        if let bestIndex { return bestIndex }
        return screens.indices.contains(primaryIndex) ? primaryIndex : screens.startIndex
    }

    private static func resized(_ window: CGRect, byWidth: CGFloat, byHeight: CGFloat, inside screen: CGRect) -> CGRect {
        resized(window, width: window.width + byWidth, height: window.height + byHeight, inside: screen)
    }

    private static func resized(_ window: CGRect, width: CGFloat, height: CGFloat, inside screen: CGRect) -> CGRect {
        let size = clampedSize(width: width, height: height, inside: screen)
        return CGRect(
            x: window.midX - size.width / 2,
            y: window.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clampedSize(of rect: CGRect, inside screen: CGRect) -> CGSize {
        clampedSize(width: rect.width, height: rect.height, inside: screen)
    }

    private static func clampedSize(width: CGFloat, height: CGFloat, inside screen: CGRect) -> CGSize {
        CGSize(
            width: min(max(0, width), max(0, screen.width)),
            height: min(max(0, height), max(0, screen.height))
        )
    }

    private static func clamped(_ rect: CGRect, inside screen: CGRect) -> CGRect {
        let size = clampedSize(of: rect, inside: screen)
        let x = min(max(rect.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(rect.minY, screen.minY), screen.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func finish(_ rect: CGRect, inside screen: CGRect) -> CGRect {
        clamped(roundedEdges(of: rect), inside: roundedEdges(of: screen))
    }

    /// Rounds edges rather than origin and size independently, so adjacent tiles share
    /// exactly the same boundary even when the screen dimensions are odd.
    private static func roundedEdges(of rect: CGRect) -> CGRect {
        let left = rect.minX.rounded()
        let right = rect.maxX.rounded()
        let top = rect.minY.rounded()
        let bottom = rect.maxY.rounded()
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}
