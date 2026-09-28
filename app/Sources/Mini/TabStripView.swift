import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, select tab: Tab)
    func tabStrip(_ strip: TabStripView, close tab: Tab)
}

/// The row of tabs in the toolbar. Tabs share the width equally up to a
/// maximum, like Safari's compact tabs.
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?

    private static let maxTabWidth: CGFloat = 240
    private static let minTabWidth: CGFloat = 72
    private static let spacing: CGFloat = 4

    private var items: [TabItemView] = []

    override var isFlipped: Bool { true }

    /// Rebuilds the row for `tabs`, reusing item views for tabs already shown.
    func update(tabs: [Tab], selected: Tab?) {
        var existing = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0.tab), $0) })
        items = tabs.map { tab in
            if let item = existing.removeValue(forKey: ObjectIdentifier(tab)) { return item }
            let item = TabItemView(tab: tab)
            item.onSelect = { [weak self] in self.map { $0.delegate?.tabStrip($0, select: tab) } }
            item.onClose = { [weak self] in self.map { $0.delegate?.tabStrip($0, close: tab) } }
            addSubview(item)
            return item
        }
        existing.values.forEach { $0.removeFromSuperview() }
        for item in items {
            item.isSelected = item.tab === selected
            item.refresh()
        }
        needsLayout = true
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    override func layout() {
        super.layout()
        guard !items.isEmpty else { return }
        let count = CGFloat(items.count)
        let fit = (bounds.width - Self.spacing * (count - 1)) / count
        let width = min(Self.maxTabWidth, max(Self.minTabWidth, fit)).rounded(.down)
        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.spacing
        }
    }
}

/// One tab: favicon or spinner, title, and a close button that replaces the
/// icon on hover.
final class TabItemView: NSView {
    let tab: Tab
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false { didSet { updateAppearance() } }

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"

        for view in [icon, spinner, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            // On hover the close button takes the icon's place, as in Safari.
            closeButton.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        titleLabel.stringValue = tab.displayTitle
        toolTip = tab.displayTitle
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isSelected ? .labelColor.withAlphaComponent(0.1)
            : isHovered ? .labelColor.withAlphaComponent(0.05) : .clear
        layer?.backgroundColor = fill.cgColor
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !isHovered
        icon.isHidden = isHovered || tab.isLoading
        if tab.isLoading && !isHovered {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance() // layer colors don't follow light/dark changes on their own
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    // Middle click closes, as in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    // Clicks in the tab select it instead of dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeClicked() { onClose?() }
}
