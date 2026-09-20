import AppKit
import Testing
@testable import Launcher

/// The panel's own arithmetic: the scroll indicator and what one scroll event is worth.
@MainActor
struct PanelTests {
    @Test("the scroll indicator's thumb is the visible share of the track, and slides to its foot")
    func scrollThumb() {
        let track: CGFloat = 100
        // Half the list on screen: half the track, at the top, then at the foot.
        #expect(ScrollPosition(first: 0, total: 10).thumb(shown: 5, in: track, minimum: 10) == (0, 50))
        #expect(ScrollPosition(first: 5, total: 10).thumb(shown: 5, in: track, minimum: 10) == (50, 50))
        // A long list keeps a thumb you can see, and it still walks the whole track.
        #expect(ScrollPosition(first: 3, total: 11).thumb(shown: 1, in: track, minimum: 10) == (27, 10))
        #expect(ScrollPosition(first: 10, total: 11).thumb(shown: 1, in: track, minimum: 10) == (90, 10))
        // Nothing to scroll: the thumb is the whole track.
        #expect(ScrollPosition(first: 0, total: 3).thumb(shown: 3, in: track, minimum: 10) == (0, 100))
    }

    @Test("a wheel notch moves one row however many lines it reports")
    func wheelSteps() {
        var accumulated: CGFloat = 0
        func step(_ deltaY: CGFloat, began: Bool = false) -> Int {
            LauncherPanel.scrollStep(deltaY: deltaY, precise: false, began: began, accumulated: &accumulated)
        }
        // A slow notch reports one line, a fast one several; both are one row.
        #expect(step(-1) == 1)
        #expect(step(-3) == 1)
        #expect(step(10) == -1)
        #expect(step(0) == 0)
    }

    @Test("a trackpad's deltas add up to a row before the selection moves, and never more than one")
    func trackpadSteps() {
        var accumulated: CGFloat = 0
        func step(_ deltaY: CGFloat, began: Bool = false) -> Int {
            LauncherPanel.scrollStep(deltaY: deltaY, precise: true, began: began, accumulated: &accumulated)
        }
        let row = ResultRowView.height
        #expect(step(-row / 4, began: true) == 0)
        #expect(step(-row / 4) == 1)
        // The remainder is dropped, so the next row takes another half row of travel.
        #expect(step(-row / 4) == 0)
        // A flick with a delta worth several rows still moves one.
        #expect(step(-row * 5) == 1)
        // A new gesture starts from nothing, and reversing direction turns the move around.
        #expect(step(row / 4, began: true) == 0)
        #expect(step(row / 2) == -1)
    }
}
