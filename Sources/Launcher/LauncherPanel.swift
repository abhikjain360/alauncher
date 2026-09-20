import AppKit

/// What the panel reports; `LauncherController` decides what it means.
@MainActor
protocol LauncherPanelDelegate: AnyObject {
    func panelQueryChanged(_ text: String)
    func panelMoveSelection(by delta: Int)
    func panelActivate()
    func panelReveal()
    func panelTab(backward: Bool)
    func panelCancel()
    func panelDidResignKey()
    func panelClickedRow(at index: Int)
    /// The mouse moved onto a row on screen.
    func panelHoveredRow(at index: Int)
    /// The wheel or a two-finger scroll, in rows: positive scrolls further down the list.
    func panelScroll(by delta: Int)
    /// ⌘C with no text selected in the field. True when the controller copied something.
    func panelCopySelection() -> Bool
}

/// Where the rows on screen sit in the whole list, for the scroll indicator.
struct ScrollPosition: Equatable {
    /// The index of the first row on screen.
    var first: Int
    /// How many rows the list holds in all.
    var total: Int

    /// The indicator's thumb in a track `height` tall: `shown` rows' share of the list, never
    /// shorter than `minimum`, sliding down the rest of the track as `first` grows.
    func thumb(shown: Int, in height: CGFloat, minimum: CGFloat) -> (top: CGFloat, height: CGFloat) {
        guard shown > 0, total > shown else { return (0, height) }
        let thumb = min(height, max(minimum, height * CGFloat(shown) / CGFloat(total)))
        let progress = min(1, max(0, CGFloat(first) / CGFloat(total - shown)))
        return (top: (height - thumb) * progress, height: thumb)
    }
}

/// The launcher window: a borderless, non-activating panel with the search field
/// and the result rows. Created once and reused, so showing it costs one frame.
@MainActor
final class LauncherPanel: NSPanel, NSWindowDelegate, NSTextFieldDelegate {
    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 56
    static let defaultPlaceholder = "Search apps and scripts, or calculate"
    private static let listPadding: CGFloat = 6

    weak var launcherDelegate: LauncherPanelDelegate?

    private let icons: IconCache
    private let container = FlippedView()
    private let searchField = NSTextField()
    /// Swapped in for password arguments.
    private let secureField = NSSecureTextField()
    private var usesSecureField = false
    private let token = TokenView()
    private let separator = NSBox()
    private let indicator = ScrollIndicator()
    private var rowViews: [ResultRowView] = []
    private var shownRows = 0
    /// Where the pointer was when the rows were last shown. A list that changes under a still
    /// pointer must not move the selection, and only a real move changes this.
    private var mouseWhenShown = NSPoint.zero
    /// Precise scroll travel not yet worth a row.
    private var scrolled: CGFloat = 0

    init(icons: IconCache) {
        self.icons = icons
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
        delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 12)
        contentView = effect
        container.frame = effect.bounds
        container.autoresizingMask = [.width, .height]
        effect.addSubview(container)

        for field in [searchField, secureField] {
            configure(field)
            container.addSubview(field)
        }
        secureField.isHidden = true
        token.isHidden = true
        container.addSubview(token)
        separator.boxType = .separator
        separator.isHidden = true
        container.addSubview(separator)
        indicator.isHidden = true
        container.addSubview(indicator)
        layoutField()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Showing

    private var targetScreen: NSScreen?

    /// Picks the screen under the mouse for the next `present()`, so `rowCapacity` counts
    /// that screen's rows.
    func prepareToShow() {
        let location = NSEvent.mouseLocation
        targetScreen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Positions the panel on the prepared screen, top edge at 22% of its height, then
    /// makes it key and focuses the field. Being a non-activating panel, it doesn't
    /// activate the app.
    func present() {
        guard let screen = targetScreen ?? NSScreen.main else { return }
        let height = contentHeight
        let frame = NSRect(x: screen.frame.midX - Self.width / 2, y: Self.topEdge(on: screen) - height, width: Self.width, height: height)
        setFrame(frame, display: false)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(activeField)
        invalidateShadow()
    }

    func focus() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(activeField)
    }

    func dismiss() {
        orderOut(nil)
    }

    var rowCapacity: Int {
        (screen ?? targetScreen).map(Self.maxRows(on:)) ?? 8
    }

    /// Rows that fit between the panel's top edge and the bottom of `screen`.
    static func maxRows(on screen: NSScreen) -> Int {
        let available = topEdge(on: screen) - screen.visibleFrame.minY - fieldHeight - 1 - listPadding * 2 - 12
        return max(1, Int(available / ResultRowView.height))
    }

    static func topEdge(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.frame.height * 0.22
    }

    // MARK: Field

    var text: String {
        (activeField.currentEditor() as? NSTextView)?.string ?? activeField.stringValue
    }

    /// Replaces the field's text and puts the cursor at the end, without a change callback.
    func setText(_ text: String) {
        if let editor = activeField.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        } else {
            activeField.stringValue = text
        }
    }

    /// Argument mode: a token with the script's title in front of the field, the
    /// argument's placeholder, and a secure field for password arguments. Nil title
    /// goes back to searching.
    func setArgumentMode(title: String?, placeholder: String?, secure: Bool) {
        token.text = title ?? ""
        token.isHidden = title == nil
        if usesSecureField != secure {
            let wasKey = isKeyWindow
            usesSecureField = secure
            searchField.isHidden = secure
            secureField.isHidden = !secure
            if !secure { secureField.stringValue = "" }
            if wasKey { makeFirstResponder(activeField) }
        }
        activeField.placeholderString = placeholder ?? Self.defaultPlaceholder
        layoutField()
    }

    private var activeField: NSTextField {
        usesSecureField ? secureField : searchField
    }

    private func configure(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 22)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = Self.defaultPlaceholder
        field.delegate = self
    }

    private func layoutField() {
        var x: CGFloat = 18
        if !token.isHidden {
            let width = token.preferredWidth
            token.frame = NSRect(x: x, y: (Self.fieldHeight - 28) / 2, width: width, height: 28)
            x += width + 10
        }
        let frame = NSRect(x: x, y: (Self.fieldHeight - 30) / 2, width: Self.width - x - 18, height: 30)
        searchField.frame = frame
        secureField.frame = frame
    }

    // MARK: Rows

    /// Shows `rows` and resizes the panel, keeping its top edge where it is. `scroll` says
    /// where they sit in the list, and is nil when they are all of it.
    func display(_ rows: [LauncherRow], selection: Int?, hint: (index: Int, text: String)? = nil, scroll: ScrollPosition? = nil) {
        for (index, row) in rows.enumerated() {
            let view = rowView(at: index)
            view.configure(row, hint: hint?.index == index ? hint?.text : nil)
            view.frame = NSRect(
                x: 0,
                y: Self.fieldHeight + 1 + Self.listPadding + CGFloat(index) * ResultRowView.height,
                width: Self.width,
                height: ResultRowView.height
            )
            view.isHidden = false
            view.isSelected = index == selection
            if let source = row.icon {
                let image = icons.icon(for: source) { [weak view] image in
                    guard let view, view.iconSource == source else { return }
                    view.setIcon(image)
                }
                view.setIcon(image)
            } else {
                view.setIcon(nil)
            }
        }
        for view in rowViews.dropFirst(rows.count) {
            view.isHidden = true
            view.isSelected = false
        }
        shownRows = rows.count
        mouseWhenShown = NSEvent.mouseLocation
        separator.frame = NSRect(x: 0, y: Self.fieldHeight, width: Self.width, height: 1)
        separator.isHidden = rows.isEmpty
        layoutIndicator(scroll)
        resize()
    }

    /// The indicator runs beside the rows, in the margin their text leaves free, and shows
    /// nothing when the whole list is on screen.
    private func layoutIndicator(_ scroll: ScrollPosition?) {
        guard shownRows > 0, let scroll, scroll.total > shownRows else {
            indicator.isHidden = true
            return
        }
        let height = CGFloat(shownRows) * ResultRowView.height
        indicator.isHidden = false
        indicator.frame = NSRect(
            // Beside the rows: their highlight stops 8 pt in from the panel's edge.
            x: Self.width - 3 - ScrollIndicator.thickness,
            y: Self.fieldHeight + 1 + Self.listPadding,
            width: ScrollIndicator.thickness,
            height: height
        )
        indicator.thumb = scroll.thumb(shown: shownRows, in: height, minimum: ScrollIndicator.minimumThumb)
        indicator.needsDisplay = true
    }

    func select(_ index: Int?) {
        for (position, view) in rowViews.enumerated() {
            view.isSelected = position == index && position < shownRows
        }
    }

    private var contentHeight: CGFloat {
        guard shownRows > 0 else { return Self.fieldHeight }
        return Self.fieldHeight + 1 + Self.listPadding * 2 + CGFloat(shownRows) * ResultRowView.height
    }

    private func resize() {
        let height = contentHeight
        guard frame.height != height else { return }
        var newFrame = frame
        newFrame.origin.y = frame.maxY - height
        newFrame.size.height = height
        setFrame(newFrame, display: isVisible)
        invalidateShadow()
    }

    private func rowView(at index: Int) -> ResultRowView {
        while rowViews.count <= index {
            let view = ResultRowView(frame: .zero)
            let position = rowViews.count
            view.onClick = { [weak self] in self?.launcherDelegate?.panelClickedRow(at: position) }
            view.onHover = { [weak self] in
                guard let self, NSEvent.mouseLocation != mouseWhenShown else { return }
                launcherDelegate?.panelHoveredRow(at: position)
            }
            container.addSubview(view)
            rowViews.append(view)
        }
        return rowViews[index]
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) {
        launcherDelegate?.panelQueryChanged(text)
    }

    /// ↑ ↓ (and ⌃P ⌃N, which the key bindings turn into moveUp:/moveDown:), Enter,
    /// Esc and Tab. While the IME has marked text these all go to the IME.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        guard let delegate = launcherDelegate else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            delegate.panelMoveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            delegate.panelMoveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            delegate.panelActivate()
        case #selector(NSResponder.cancelOperation(_:)):
            delegate.panelCancel()
        case #selector(NSResponder.insertTab(_:)):
            delegate.panelTab(backward: false)
        case #selector(NSResponder.insertBacktab(_:)):
            delegate.panelTab(backward: true)
        default:
            return false
        }
        return true
    }

    /// ⌘Enter reveals the selection. ⌘A/C/V/X are handled here too, since an agent
    /// app may have no Edit menu to route them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editor = activeField.currentEditor() as? NSTextView
        guard event.type == .keyDown, editor?.hasMarkedText() != true else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }

        if event.keyCode == 36 || event.keyCode == 76 {
            launcherDelegate?.panelReveal()
            return true
        }
        guard let editor else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": editor.selectAll(nil)
        case "c":
            // With no text selected, the selected row gets to copy first: an emoji row does.
            if editor.selectedRange().length > 0 || launcherDelegate?.panelCopySelection() != true {
                editor.copy(nil)
            }
        case "v": editor.paste(nil)
        case "x": editor.cut(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// A wheel or two-finger scroll scrolls the list. The rows are plain views the panel lays
    /// out itself, so there is no scroll view to take the event.
    override func scrollWheel(with event: NSEvent) {
        let step = Self.scrollStep(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            began: event.phase == .began,
            accumulated: &scrolled
        )
        guard step != 0 else { return }
        launcherDelegate?.panelScroll(by: step)
    }

    /// How far one scroll event moves the list: one row, never more, so that neither a spun
    /// wheel nor a flicked trackpad skips rows. A wheel's line count is ignored, since it grows
    /// with how fast the wheel turns; precise deltas add up until they are worth a row.
    static func scrollStep(deltaY: CGFloat, precise: Bool, began: Bool, accumulated: inout CGFloat) -> Int {
        if began { accumulated = 0 }
        guard deltaY != 0 else { return 0 }
        // Scrolling up, towards the top of the list, is a negative move.
        guard precise else { return deltaY > 0 ? -1 : 1 }
        accumulated += deltaY
        guard abs(accumulated) >= ResultRowView.height / 2 else { return 0 }
        let step = accumulated > 0 ? -1 : 1
        accumulated = 0
        return step
    }

    func windowDidResignKey(_ notification: Notification) {
        launcherDelegate?.panelDidResignKey()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Top-to-bottom layout.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The argument-mode token: the script's title in a rounded chip.
private final class TokenView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    /// Sized by the label's cell, which includes the padding the cell draws around the text. A
    /// truncating label's intrinsic width leaves that out, so the title would lose its tail.
    var preferredWidth: CGFloat {
        min(240, ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) + 16)
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 8, y: (bounds.height - height) / 2, width: max(0, bounds.width - 16), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// A scroll indicator, not a scroller: it shows how far down a list the rows on screen are,
/// and never takes a click, since the list scrolls with the selection.
private final class ScrollIndicator: NSView {
    static let thickness: CGFloat = 3
    static let minimumThumb: CGFloat = 18

    /// Measured from the top of the track, which is why the view is flipped.
    var thumb: (top: CGFloat, height: CGFloat) = (0, 0)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: thumb.top, width: bounds.width, height: thumb.height)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}
