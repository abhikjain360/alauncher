import AppKit
import QuartzCore

/// What the bottom-of-screen pill shows.
public enum PillState: Equatable, Sendable {
    case hidden
    /// Recording; the level meter is driven separately by `OverlayPill.setLevel`.
    case recording
    /// Waiting for the speech model, with an optional detail such as "downloading 42%".
    case loading(String?)
    /// Transcribing or post-processing.
    case processing
}

/// The small pill at the bottom of the screen. It never takes focus or clicks.
///
/// A borderless non-activating panel at `.statusBar` level, drawn with CALayers: a red dot and
/// five level bars while recording, an amber dot and a short text while loading, three pulsing
/// dots while processing, and a text pill (red-tinted for errors) for flashes.
@MainActor
public final class OverlayPill {
    public static let shared = OverlayPill()

    private enum Metrics {
        static let height: CGFloat = 22
        static let iconWidth: CGFloat = 60
        static let maxWidth: CGFloat = 480
        static let bottomInset: CGFloat = 24
        static let padding: CGFloat = 10
        static let dotSize: CGFloat = 8
        static let gap: CGFloat = 6
        static let barCount = 5
        static let barWidth: CGFloat = 3
        static let barGap: CGFloat = 3
        static let barMaxHeight: CGFloat = 12
        static let barMinHeight: CGFloat = 2
        static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// The dot sits 14 pt from the left edge; the bars end the same 14 pt from the right.
        static let recordingWidth: CGFloat = 14 + dotSize + 8
            + CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap + 14
    }

    private var panel: NSPanel?
    private let background = CALayer()
    private let dot = CALayer()
    private var bars: [CALayer] = []
    private var pulseDots: [CALayer] = []
    private let textLayer = CATextLayer()

    private var state: PillState = .hidden
    private var flashMessage: (text: String, isError: Bool)?
    private var flashGeneration = 0
    private var displayedLevel: CGFloat = 0

    private init() {}

    public func setState(_ state: PillState) {
        guard state != self.state else { return }
        self.state = state
        if state == .recording { displayedLevel = 0 }
        if flashMessage == nil { render() }
    }

    /// Mic level in 0...1 while recording.
    public func setLevel(_ level: Float) {
        guard state == .recording, flashMessage == nil, panel?.isVisible == true else { return }
        let target = CGFloat(min(1, max(0, level)))
        // Rise at once, fall gently.
        displayedLevel = max(target, displayedLevel * 0.8)
        layoutBars()
    }

    /// Shows a short message for `duration` seconds, then goes back to the current state.
    public func flash(_ text: String, isError: Bool = false, duration: TimeInterval = 2) {
        flashGeneration += 1
        let generation = flashGeneration
        flashMessage = (text, isError)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flashGeneration == generation else { return }
                self.flashMessage = nil
                self.render()
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        if let flashMessage {
            show(text: flashMessage.text, dotColor: nil, tint: flashMessage.isError ? NSColor.systemRed : nil)
            return
        }
        switch state {
        case .hidden:
            stopPulse()
            panel?.orderOut(nil)
        case .recording:
            showIcons(recording: true)
        case .loading(let detail):
            show(text: detail ?? "loading speech model", dotColor: .systemOrange, tint: nil)
        case .processing:
            showIcons(recording: false)
        }
    }

    private func showIcons(recording: Bool) {
        let panel = ensurePanel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.isHidden = true
        dot.isHidden = !recording
        bars.forEach { $0.isHidden = !recording }
        pulseDots.forEach { $0.isHidden = recording }
        background.backgroundColor = NSColor(white: 0.08, alpha: 0.86).cgColor
        resize(panel, width: recording ? Metrics.recordingWidth : Metrics.iconWidth)
        if recording {
            dot.backgroundColor = NSColor.systemRed.cgColor
            dot.frame = CGRect(x: 14, y: (Metrics.height - Metrics.dotSize) / 2, width: Metrics.dotSize, height: Metrics.dotSize)
            layoutBars()
            stopPulse()
        } else {
            let size: CGFloat = 5
            let spacing: CGFloat = 6
            let total = CGFloat(pulseDots.count) * size + CGFloat(pulseDots.count - 1) * spacing
            for (index, layer) in pulseDots.enumerated() {
                layer.frame = CGRect(
                    x: (Metrics.iconWidth - total) / 2 + CGFloat(index) * (size + spacing),
                    y: (Metrics.height - size) / 2, width: size, height: size
                )
            }
            startPulse()
        }
        CATransaction.commit()
        present(panel)
    }

    private func show(text: String, dotColor: NSColor?, tint: NSColor?) {
        let panel = ensurePanel()
        stopPulse()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.isHidden = true }
        pulseDots.forEach { $0.isHidden = true }
        dot.isHidden = dotColor == nil
        textLayer.isHidden = false

        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Metrics.font]).width)
        let leading = Metrics.padding + (dotColor == nil ? 0 : Metrics.dotSize + Metrics.gap)
        let width = min(Metrics.maxWidth, max(Metrics.iconWidth, leading + textWidth + Metrics.padding))
        resize(panel, width: width)

        if let dotColor {
            dot.backgroundColor = dotColor.cgColor
            dot.frame = CGRect(x: Metrics.padding, y: (Metrics.height - Metrics.dotSize) / 2, width: Metrics.dotSize, height: Metrics.dotSize)
        }
        let base = NSColor(white: 0.08, alpha: 0.86)
        background.backgroundColor = (tint.map { base.blended(withFraction: 0.45, of: $0) ?? base } ?? base).cgColor
        textLayer.string = text
        let lineHeight = ceil(Metrics.font.ascender - Metrics.font.descender)
        textLayer.frame = CGRect(
            x: leading, y: (Metrics.height - lineHeight) / 2 - 0.5,
            width: width - leading - Metrics.padding, height: lineHeight
        )
        CATransaction.commit()
        present(panel)
    }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let startX: CGFloat = 14 + Metrics.dotSize + 8
        // Middle bars move most, like a small meter.
        let weights: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]
        for (index, bar) in bars.enumerated() {
            let height = Metrics.barMinHeight + (Metrics.barMaxHeight - Metrics.barMinHeight) * displayedLevel * weights[index]
            bar.frame = CGRect(
                x: startX + CGFloat(index) * (Metrics.barWidth + Metrics.barGap),
                y: (Metrics.height - height) / 2, width: Metrics.barWidth, height: height
            )
        }
        CATransaction.commit()
    }

    private func startPulse() {
        for (index, layer) in pulseDots.enumerated() where layer.animation(forKey: "pulse") == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.25
            animation.toValue = 1
            animation.duration = 0.45
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.15
            animation.fillMode = .backwards
            layer.add(animation, forKey: "pulse")
        }
    }

    private func stopPulse() {
        pulseDots.forEach { $0.removeAnimation(forKey: "pulse") }
    }

    // MARK: - Window

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.iconWidth, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.iconWidth, height: Metrics.height))
        view.wantsLayer = true
        let root = CALayer()
        view.layer = root
        panel.contentView = view

        background.cornerRadius = Metrics.height / 2
        background.borderWidth = 0.5
        background.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        root.addSublayer(background)

        dot.cornerRadius = Metrics.dotSize / 2
        background.addSublayer(dot)
        for _ in 0..<Metrics.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            bar.cornerRadius = Metrics.barWidth / 2
            background.addSublayer(bar)
            bars.append(bar)
        }
        for _ in 0..<3 {
            let pulse = CALayer()
            pulse.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            pulse.cornerRadius = 2.5
            background.addSublayer(pulse)
            pulseDots.append(pulse)
        }
        textLayer.font = Metrics.font
        textLayer.fontSize = Metrics.font.pointSize
        textLayer.foregroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        textLayer.truncationMode = .end
        textLayer.alignmentMode = .left
        background.addSublayer(textLayer)

        self.panel = panel
        return panel
    }

    private func resize(_ panel: NSPanel, width: CGFloat) {
        let screen = panel.isVisible ? (panel.screen ?? Self.screenUnderMouse()) : Self.screenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: round(visible.midX - width / 2), y: visible.minY + Metrics.bottomInset,
            width: width, height: Metrics.height
        )
        panel.setFrame(frame, display: false)
        let scale = screen?.backingScaleFactor ?? 2
        background.frame = CGRect(x: 0, y: 0, width: width, height: Metrics.height)
        textLayer.contentsScale = scale
        background.contentsScale = scale
    }

    private func present(_ panel: NSPanel) {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
