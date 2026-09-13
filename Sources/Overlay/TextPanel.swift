import AppKit

/// A popup of selectable text: Ask answers, and script output from the launcher.
///
/// A non-activating panel that becomes key, so it gets the keyboard while the other app stays
/// frontmost (and insertion later lands there). Upper third of the active screen, 560 pt wide;
/// it grows with its text up to 60% of the screen height, then scrolls.
/// Keys: Enter calls `onEnter` with the last entry's body and closes; ⌘C copies the selection
/// (or the last body); Esc closes.
@MainActor
public final class TextPanel {
    public static let shared = TextPanel()

    public struct Entry: Equatable, Sendable {
        public var heading: String
        public var body: String

        public init(heading: String, body: String) {
            self.heading = heading
            self.body = body
        }
    }

    /// Gets the last entry's body when Enter is pressed, after the panel has closed; nil means
    /// Enter copies it.
    public var onEnter: ((String) -> Void)?
    /// Called once when the panel closes, however it closes.
    public var onClose: (() -> Void)?

    public var isOpen: Bool { panel?.isVisible == true }

    private enum Metrics {
        static let width: CGFloat = 560
        static let padding: CGFloat = 16
        static let hintHeight: CGFloat = 16
        static let maxScreenFraction: CGFloat = 0.6
        static let bodyFont = NSFont.systemFont(ofSize: 14)
        static let headingFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    }

    private var entries: [Entry] = []
    private var panel: KeyablePanel?
    private var textView: PanelTextView?
    private var scrollView: NSScrollView?
    private var hintLabel: NSTextField?
    private var topEdge: CGFloat?
    /// Character offset where the newest entry starts.
    private var latestEntryStart = 0

    private init() {}

    /// Enter, and Cmd+C without a selection, act on the last entry, so pass entries oldest first.
    /// `scrollToLatest` opens scrolled to that last entry.
    public func show(entries: [Entry], hint: String, scrollToLatest: Bool = false) {
        let panel = ensurePanel()
        self.entries = entries
        let text = NSMutableAttributedString()
        latestEntryStart = 0
        for (index, entry) in entries.enumerated() {
            if index > 0 { text.append(Self.separator) }
            latestEntryStart = text.length
            text.append(Self.attributed(entry))
        }
        textView?.textStorage?.setAttributedString(text)
        hintLabel?.stringValue = hint
        topEdge = nil
        layout(scrollToLatest: scrollToLatest)
        panel.makeKeyAndOrderFront(nil)
        if let textView { panel.makeFirstResponder(textView) }
    }

    public func appendEntry(_ entry: Entry) {
        guard isOpen, let storage = textView?.textStorage else { return }
        if !entries.isEmpty { storage.append(Self.separator) }
        entries.append(entry)
        latestEntryStart = storage.length
        storage.append(Self.attributed(entry))
        layout(scrollToLatest: true)
    }

    /// Streams text into the last entry's body.
    public func appendToLast(_ text: String) {
        guard isOpen, !text.isEmpty else { return }
        guard !entries.isEmpty else {
            appendEntry(Entry(heading: "", body: text))
            return
        }
        entries[entries.count - 1].body += text
        textView?.textStorage?.append(NSAttributedString(string: text, attributes: Self.bodyAttributes))
        layout(scrollToLatest: true)
    }

    public func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        entries = []
        let handler = onClose
        onClose = nil
        onEnter = nil
        handler?()
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76, !modifiers.contains(.command) {
            enter()
            return true
        }
        if event.keyCode == 53 {
            close()
            return true
        }
        guard modifiers.subtracting([.capsLock, .numericPad, .function]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            copySelectionOrLast()
            return true
        case "a":
            textView?.selectAll(nil)
            return true
        case "w":
            close()
            return true
        default:
            return false
        }
    }

    private func enter() {
        let body = entries.last?.body ?? ""
        guard let handler = onEnter else {
            copy(body)
            close()
            return
        }
        close()
        // Let the frontmost app's window take the keyboard back before it receives anything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { handler(body) }
    }

    private func copySelectionOrLast() {
        if let textView, let range = textView.selectedRanges.first?.rangeValue, range.length > 0,
           let storage = textView.textStorage {
            copy((storage.string as NSString).substring(with: range))
        } else {
            copy(entries.last?.body ?? "")
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        OverlayPill.shared.flash("copied “\(Self.preview(text))”", duration: 1.5)
    }

    /// The start of `text` on one line, so a copy shows what it took.
    private static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 40 ? flat.prefix(40) + "…" : flat
    }

    // MARK: - Text

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: Metrics.bodyFont, .foregroundColor: NSColor.labelColor]
    }

    private static var headingAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        return [.font: Metrics.headingFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
    }

    private static var separator: NSAttributedString {
        NSAttributedString(string: "\n\n", attributes: bodyAttributes)
    }

    private static func attributed(_ entry: Entry) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if !entry.heading.isEmpty {
            result.append(NSAttributedString(string: entry.heading + "\n", attributes: headingAttributes))
        }
        result.append(NSAttributedString(string: entry.body, attributes: bodyAttributes))
        return result
    }

    // MARK: - Window

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let frame = NSRect(x: 0, y: 0, width: Metrics.width, height: 120)
        let panel = KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TextKit 1 from the start, so the layout manager used for scrolling is never swapped in
        // on first access.
        let textView = PanelTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: Metrics.width - 2 * Metrics.padding, height: 40)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        scrollView.documentView = textView
        effect.addSubview(scrollView)

        let hint = NSTextField(labelWithString: "")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        effect.addSubview(hint)

        self.panel = panel
        self.textView = textView
        self.scrollView = scrollView
        hintLabel = hint
        return panel
    }

    /// Sizes the panel to its text, up to `maxScreenFraction` of the screen, then scrolls.
    private func layout(scrollToLatest: Bool) {
        guard let panel, let textView, let scrollView, let hintLabel,
              let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        let screen = panel.isVisible ? (panel.screen ?? Self.activeScreen()) : Self.activeScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let textWidth = Metrics.width - 2 * Metrics.padding
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        // Measure the text itself. The layout manager could still report the old height right after
        // new text arrived, which kept the first answer in a panel too short to show any of it.
        let textHeight = Self.height(of: textView.textStorage, width: textWidth)
        let chrome = Metrics.padding * 2 + Metrics.hintHeight + 8
        let maxHeight = floor(visible.height * Metrics.maxScreenFraction)
        let height = min(maxHeight, max(60, textHeight + chrome))

        // Keep the top edge still while the text grows downward.
        let top = topEdge ?? (visible.maxY - floor(visible.height / 6))
        topEdge = top
        let frame = NSRect(x: round(visible.midX - Metrics.width / 2), y: max(visible.minY, top - height), width: Metrics.width, height: height)
        panel.setFrame(frame, display: true)

        let scrollHeight = height - chrome
        scrollView.frame = NSRect(x: Metrics.padding, y: Metrics.padding + Metrics.hintHeight + 8, width: textWidth, height: scrollHeight)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(textHeight, scrollHeight))
        hintLabel.frame = NSRect(x: Metrics.padding, y: Metrics.padding - 2, width: textWidth, height: Metrics.hintHeight)
        if scrollToLatest, let storage = textView.textStorage, storage.length > 0 {
            // The newest entry's first line goes to the top, so a long answer reads from its start.
            let glyph = layoutManager.glyphIndexForCharacter(at: min(latestEntryStart, storage.length - 1))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            textView.scroll(NSPoint(x: 0, y: line.minY))
        }
    }

    private static func height(of text: NSAttributedString?, width: CGFloat) -> CGFloat {
        guard let text, text.length > 0 else { return 0 }
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }

    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PanelTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc reaches here when keyDown was bypassed.
        if let event = NSApp.currentEvent, onKey?(event) == true { return }
        super.cancelOperation(sender)
    }
}
