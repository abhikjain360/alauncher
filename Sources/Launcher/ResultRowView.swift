import AppKit

/// One result row: a 32 pt icon, the title with its matched characters in
/// semibold, the subtitle in the secondary color, and a right-aligned hint.
@MainActor
final class ResultRowView: NSView {
    static let height: CGFloat = 44

    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            if isSelected != oldValue { needsDisplay = true }
        }
    }
    private(set) var iconSource: IconSource?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private static let titleFont = NSFont.systemFont(ofSize: 14)
    private static let matchFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .right
        for view in [iconView, titleLabel, hintLabel] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// `hint` replaces the row's own hint, e.g. "press ⏎ again to run".
    func configure(_ row: LauncherRow, hint: String? = nil) {
        titleLabel.attributedStringValue = Self.title(for: row)
        hintLabel.stringValue = hint ?? row.hint
        hintLabel.textColor = hint == nil ? .secondaryLabelColor : .controlAccentColor
        iconView.alphaValue = row.isEnabled ? 1 : 0.5
        if iconSource != row.icon {
            iconSource = row.icon
            iconView.image = nil
        }
        needsLayout = true
    }

    func setIcon(_ image: NSImage?) {
        iconView.image = image
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconView.frame = NSRect(x: 16, y: (height - 32) / 2, width: 32, height: 32)

        let hintWidth = hintLabel.stringValue.isEmpty ? 0 : ceil(hintLabel.intrinsicContentSize.width)
        hintLabel.frame = NSRect(x: bounds.width - 18 - hintWidth, y: (height - 16) / 2, width: hintWidth, height: 16)

        let titleX: CGFloat = 60
        let titleRight = hintWidth > 0 ? hintLabel.frame.minX - 12 : bounds.width - 18
        titleLabel.frame = NSRect(x: titleX, y: (height - 18) / 2, width: max(0, titleRight - titleX), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    /// The whole row takes the click, labels included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    static func title(for row: LauncherRow) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color: NSColor = row.isEnabled ? .labelColor : .secondaryLabelColor
        let text = NSMutableAttributedString(
            string: row.title,
            attributes: [.font: titleFont, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        if !row.titlePositions.isEmpty {
            let indices = Array(row.title.indices)
            for offset in row.titlePositions where offset >= 0 && offset < indices.count {
                let start = indices[offset]
                text.addAttribute(.font, value: matchFont, range: NSRange(start..<row.title.index(after: start), in: row.title))
            }
        }
        if let subtitle = row.subtitle, !subtitle.isEmpty {
            let singleLine = subtitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            text.append(NSAttributedString(
                string: "  " + singleLine,
                attributes: [.font: subtitleFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            ))
        }
        return text
    }
}
