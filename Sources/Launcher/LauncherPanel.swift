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
    /// ⌘C with no text selected in the field. True when the controller copied something.
    func panelCopySelection() -> Bool
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
    private var rowViews: [ResultRowView] = []
    private var shownRows = 0
    /// Scroll travel not yet worth a row.
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

    /// Shows `rows` and resizes the panel, keeping its top edge where it is.
    func display(_ rows: [LauncherRow], selection: Int?, hint: (index: Int, text: String)? = nil) {
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
        separator.frame = NSRect(x: 0, y: Self.fieldHeight, width: Self.width, height: 1)
        separator.isHidden = rows.isEmpty
        resize()
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

    /// A wheel or two-finger scroll moves the selection, which scrolls the list. The rows are
    /// plain views the panel lays out itself, so there is no scroll view to take the event.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrolled = 0 }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * ResultRowView.height
        let rows = Int(scrolled / ResultRowView.height)
        guard rows != 0 else { return }
        scrolled -= CGFloat(rows) * ResultRowView.height
        // Scrolling up, towards the top of the list, is a negative move.
        for _ in 0..<abs(rows) {
            launcherDelegate?.panelMoveSelection(by: rows > 0 ? -1 : 1)
        }
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
