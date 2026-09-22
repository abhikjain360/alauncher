import AppKit
import Foundation
import Testing
@testable import Windows

struct WindowsTests {
    private let screen = CGRect(x: 120, y: 40, width: 1440, height: 900)
    private let window = CGRect(x: 500, y: 260, width: 520, height: 360)

    @Test("every command has a unique title and a symbol available on macOS")
    func commandsHaveTitlesAndSymbols() {
        let commands = WindowCommand.allCases
        #expect(Set(commands.map(\.title)).count == commands.count)
        for command in commands {
            #expect(!command.title.isEmpty)
            #expect(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test("every command has a finite whole-point frame")
    func everyCommandHasGeometry() {
        for command in WindowCommand.allCases {
            let frame = WindowGeometry.frame(for: command, in: screen, window: window)
            #expect(frame.minX == frame.minX.rounded())
            #expect(frame.minY == frame.minY.rounded())
            #expect(frame.maxX == frame.maxX.rounded())
            #expect(frame.maxY == frame.maxY.rounded())
            #expect(frame.minX >= screen.minX)
            #expect(frame.minY >= screen.minY)
            #expect(frame.maxX <= screen.maxX)
            #expect(frame.maxY <= screen.maxY)
        }
    }

    @Test("halves and quarters meet at exact rounded boundaries")
    func halvesAndQuarters() {
        let left = WindowGeometry.frame(for: .leftHalf, in: screen, window: window)
        let right = WindowGeometry.frame(for: .rightHalf, in: screen, window: window)
        #expect(left == CGRect(x: 120, y: 40, width: 720, height: 900))
        #expect(right == CGRect(x: 840, y: 40, width: 720, height: 900))
        #expect(left.maxX == right.minX)
        #expect(left.minY == right.minY)
        #expect(left.maxY == right.maxY)

        #expect(WindowGeometry.frame(for: .topHalf, in: screen, window: window) == CGRect(x: 120, y: 40, width: 1440, height: 450))
        #expect(WindowGeometry.frame(for: .bottomHalf, in: screen, window: window) == CGRect(x: 120, y: 490, width: 1440, height: 450))
        #expect(WindowGeometry.frame(for: .centerHalf, in: screen, window: window) == CGRect(x: 480, y: 40, width: 720, height: 900))

        let topLeft = WindowGeometry.frame(for: .topLeft, in: screen, window: window)
        let topRight = WindowGeometry.frame(for: .topRight, in: screen, window: window)
        let bottomLeft = WindowGeometry.frame(for: .bottomLeft, in: screen, window: window)
        let bottomRight = WindowGeometry.frame(for: .bottomRight, in: screen, window: window)
        #expect(topLeft == CGRect(x: 120, y: 40, width: 720, height: 450))
        #expect(topRight == CGRect(x: 840, y: 40, width: 720, height: 450))
        #expect(bottomLeft == CGRect(x: 120, y: 490, width: 720, height: 450))
        #expect(bottomRight == CGRect(x: 840, y: 490, width: 720, height: 450))
        #expect(topLeft.maxX == topRight.minX)
        #expect(topLeft.maxY == bottomLeft.minY)
        #expect(topRight.maxY == bottomRight.minY)
    }

    @Test("thirds cover an odd-width screen without gaps")
    func oddThirds() {
        let oddScreen = CGRect(x: 37, y: 13, width: 1441, height: 901)
        let first = WindowGeometry.frame(for: .firstThird, in: oddScreen, window: window)
        let center = WindowGeometry.frame(for: .centerThird, in: oddScreen, window: window)
        let last = WindowGeometry.frame(for: .lastThird, in: oddScreen, window: window)
        #expect(first == CGRect(x: 37, y: 13, width: 480, height: 901))
        #expect(center == CGRect(x: 517, y: 13, width: 481, height: 901))
        #expect(last == CGRect(x: 998, y: 13, width: 480, height: 901))
        #expect(first.maxX == center.minX)
        #expect(center.maxX == last.minX)
        #expect(last.maxX == oddScreen.maxX)

        let firstTwo = WindowGeometry.frame(for: .firstTwoThirds, in: oddScreen, window: window)
        let lastTwo = WindowGeometry.frame(for: .lastTwoThirds, in: oddScreen, window: window)
        #expect(firstTwo == CGRect(x: 37, y: 13, width: 961, height: 901))
        #expect(lastTwo == CGRect(x: 517, y: 13, width: 961, height: 901))
        #expect(firstTwo.minX == oddScreen.minX)
        #expect(lastTwo.maxX == oddScreen.maxX)
    }

    @Test("full size and center commands keep results inside the screen")
    func fullSizeCommands() {
        #expect(WindowGeometry.frame(for: .maximize, in: screen, window: window) == screen)
        #expect(WindowGeometry.frame(for: .almostMaximize, in: screen, window: window) == CGRect(x: 192, y: 85, width: 1296, height: 810))
        #expect(WindowGeometry.frame(for: .maximizeHeight, in: screen, window: CGRect(x: -200, y: 200, width: 1800, height: 300)) == screen)
        #expect(WindowGeometry.frame(for: .maximizeWidth, in: screen, window: CGRect(x: 200, y: -50, width: 300, height: 1100)) == screen)

        // Restore fits a remembered frame onto whatever display holds it now.
        #expect(WindowGeometry.fitted(CGRect(x: 3000, y: 3000, width: 400, height: 300), inside: screen) == CGRect(x: 1160, y: 640, width: 400, height: 300))

        let centered = WindowGeometry.frame(for: .center, in: screen, window: window)
        #expect(centered == CGRect(x: 580, y: 310, width: 520, height: 360))
        #expect(centered.midX == screen.midX)
        #expect(centered.midY == screen.midY)
    }

    @Test("resizing and edge moves clamp oversized windows")
    func resizingAndMoves() {
        let smallScreen = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let oversized = CGRect(x: -200, y: -100, width: 1400, height: 1000)
        #expect(WindowGeometry.frame(for: .makeLarger, in: smallScreen, window: oversized) == smallScreen)
        #expect(WindowGeometry.frame(for: .moveLeft, in: smallScreen, window: oversized) == smallScreen)
        #expect(WindowGeometry.frame(for: .moveRight, in: smallScreen, window: oversized) == smallScreen)
        #expect(WindowGeometry.frame(for: .moveUp, in: smallScreen, window: oversized) == smallScreen)
        #expect(WindowGeometry.frame(for: .moveDown, in: smallScreen, window: oversized) == smallScreen)

        let moved = CGRect(x: 500, y: 300, width: 200, height: 180)
        #expect(WindowGeometry.frame(for: .moveLeft, in: smallScreen, window: moved) == CGRect(x: 100, y: 300, width: 200, height: 180))
        #expect(WindowGeometry.frame(for: .moveRight, in: smallScreen, window: moved) == CGRect(x: 900, y: 300, width: 200, height: 180))
        #expect(WindowGeometry.frame(for: .moveUp, in: smallScreen, window: moved) == CGRect(x: 500, y: 50, width: 200, height: 180))
        #expect(WindowGeometry.frame(for: .moveDown, in: smallScreen, window: moved) == CGRect(x: 500, y: 670, width: 200, height: 180))
    }

    @Test("make smaller has a fifth-of-screen floor and keeps the center")
    func makeSmallerFloor() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let window = CGRect(x: 520, y: 390, width: 150, height: 100)
        let smaller = WindowGeometry.frame(for: .makeSmaller, in: screen, window: window)
        #expect(smaller == CGRect(x: 495, y: 360, width: 200, height: 160))
        #expect(smaller.midX == window.midX)
        #expect(smaller.midY == window.midY)

        let larger = WindowGeometry.frame(for: .makeLarger, in: screen, window: window)
        #expect(larger == CGRect(x: 470, y: 350, width: 250, height: 180))
    }

    @Test("next and previous display map position and size proportionally")
    func proportionalDisplayMapping() {
        let source = CGRect(x: 0, y: 20, width: 1200, height: 800)
        let target = CGRect(x: 1200, y: -100, width: 1800, height: 1000)
        let window = CGRect(x: 300, y: 220, width: 600, height: 400)
        let expected = CGRect(x: 1650, y: 150, width: 900, height: 500)
        #expect(WindowGeometry.frame(for: .nextDisplay, from: source, to: target, window: window) == expected)
        #expect(WindowGeometry.frame(for: .previousDisplay, from: source, to: target, window: window) == expected)

        let tooLarge = CGRect(x: -100, y: -200, width: 2000, height: 1500)
        #expect(WindowGeometry.frame(for: .nextDisplay, from: source, to: target, window: tooLarge) == target)
    }

    @Test("screen conversion handles displays above, below, left and right")
    func screenConversion() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cases = [
            CGRect(x: 0, y: 900, width: 1200, height: 800),
            CGRect(x: 0, y: -700, width: 1200, height: 700),
            CGRect(x: -1000, y: 0, width: 1000, height: 900),
            CGRect(x: 1440, y: 0, width: 1600, height: 900),
        ]
        let converted = cases.map { WindowGeometry.accessibilityRect($0, primaryFrame: primary) }
        #expect(converted[0] == CGRect(x: 0, y: -800, width: 1200, height: 800))
        #expect(converted[1] == CGRect(x: 0, y: 900, width: 1200, height: 700))
        #expect(converted[2] == CGRect(x: -1000, y: 0, width: 1000, height: 900))
        #expect(converted[3] == CGRect(x: 1440, y: 0, width: 1600, height: 900))
    }

    @Test("window screen choice prefers center, then intersection, then primary")
    func screenChoice() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let positions = [
            CGRect(x: 0, y: -800, width: 1200, height: 800),
            CGRect(x: 0, y: 900, width: 1200, height: 700),
            CGRect(x: -1000, y: 0, width: 1000, height: 900),
            CGRect(x: 1440, y: 0, width: 1600, height: 900),
        ]
        for secondary in positions {
            let screens = [primary, secondary]
            #expect(WindowGeometry.screenIndex(containing: secondary.insetBy(dx: 100, dy: 100), in: screens) == 1)
        }

        let mostlySecondary = CGRect(x: 1250, y: 100, width: 400, height: 400)
        #expect(WindowGeometry.screenIndex(containing: mostlySecondary, in: [primary, positions[3]]) == 1)
        #expect(WindowGeometry.screenIndex(containing: CGRect(x: 3000, y: 3000, width: 20, height: 20), in: [primary, positions[3]]) == 0)
    }

    @Test("restore memory keeps the frame from before a run of commands, and evicts its LRU")
    func restoreMemory() {
        let store = RestoreStore()
        let first = AXElementBox(AXUIElementCreateApplication(10))
        let sameFirst = AXElementBox(AXUIElementCreateApplication(10))
        let second = AXElementBox(AXUIElementCreateApplication(11))
        let firstFrame = CGRect(x: 1, y: 2, width: 3, height: 4)
        let secondFrame = CGRect(x: 5, y: 6, width: 7, height: 8)
        let tiled = CGRect(x: 0, y: 0, width: 720, height: 900)

        store.willMove(first, from: firstFrame)
        store.didMove(first, to: tiled, requested: tiled)
        store.willMove(second, from: secondFrame)
        // A second command in the run keeps the original, a point of drift included.
        store.willMove(sameFirst, from: tiled.offsetBy(dx: 1, dy: 0))
        #expect(store.original(for: first) == firstFrame)
        #expect(store.original(for: second) == secondFrame)
        // The user moved the window since, so a new run starts from where it is.
        let moved = CGRect(x: 40, y: 40, width: 300, height: 200)
        store.willMove(first, from: moved)
        #expect(store.original(for: sameFirst) == moved)
        #expect(store.take(sameFirst) == moved)
        #expect(store.take(first) == nil)
        #expect(store.take(second) == secondFrame)

        // An app that applies the frame late reads back unchanged; the requested frame still counts.
        let third = AXElementBox(AXUIElementCreateApplication(12))
        let thirdFrame = CGRect(x: 9, y: 9, width: 90, height: 90)
        store.willMove(third, from: thirdFrame)
        store.didMove(third, to: thirdFrame, requested: tiled)
        store.willMove(third, from: tiled)
        #expect(store.original(for: third) == thirdFrame)
        #expect(store.take(third) == thirdFrame)

        for index in 0..<RestoreStore.capacity {
            store.willMove(AXElementBox(AXUIElementCreateApplication(pid_t(100 + index))), from: CGRect(x: index, y: 0, width: 1, height: 1))
        }
        #expect(store.count == RestoreStore.capacity)
        // Another command on the oldest window keeps it in memory; the next-oldest goes instead.
        let oldest = AXElementBox(AXUIElementCreateApplication(100))
        store.didMove(oldest, to: tiled, requested: tiled)
        store.willMove(oldest, from: tiled)
        store.willMove(AXElementBox(AXUIElementCreateApplication(999)), from: .zero)
        #expect(store.count == RestoreStore.capacity)
        #expect(store.original(for: AXElementBox(AXUIElementCreateApplication(101))) == nil)
        #expect(store.original(for: oldest) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
