import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, select tab: Tab)
    func tabStrip(_ strip: TabStripView, close tab: Tab)
    /// The user dragged `tab` to `index`.
    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int)
}

/// The row of tabs in the toolbar. Tabs share the width equally up to a
/// maximum, like Safari's compact tabs. Crowded tabs drop their titles and
/// show only the icon; past that the row scrolls to keep the selected tab in
/// view. Tabs can be dragged to reorder them.
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?

    private static let maxTabWidth: CGFloat = 240
    /// Below this, tabs show only their icon.
    private static let titleMinWidth: CGFloat = 64
    private static let minTabWidth: CGFloat = 34
    private static let spacing: CGFloat = 4
    private static let animationDuration = 0.18

    private var items: [TabItemView] = []
    private var selectedItem: TabItemView?
    /// How far the row is scrolled when the tabs don't fit.
    private var scrollOffset: CGFloat = 0
    private var drag: (item: TabItemView, startX: CGFloat, originX: CGFloat, moved: Bool)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the row for `tabs`, reusing item views for tabs already shown.
    /// Tabs that move slide to their new place, and new ones fade in.
    func update(tabs: [Tab], selected: Tab?) {
        // The row changed under a drag; the drag's order no longer holds.
        drag = nil
        var existing = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0.tab), $0) })
        var added: [TabItemView] = []
        items = tabs.map { tab in
            if let item = existing.removeValue(forKey: ObjectIdentifier(tab)) { return item }
            let item = TabItemView(tab: tab)
            item.strip = self
            item.onSelect = { [weak self] in self.map { $0.delegate?.tabStrip($0, select: tab) } }
            item.onClose = { [weak self] in self.map { $0.delegate?.tabStrip($0, close: tab) } }
            addSubview(item)
            added.append(item)
            return item
        }
        existing.values.forEach { $0.removeFromSuperview() }
        selectedItem = items.first { $0.tab === selected }
        for item in items {
            item.isSelected = item === selectedItem
            item.refresh()
        }
        let animate = window != nil && !items.isEmpty && (added.count < items.count || !existing.isEmpty)
        layoutItems(animated: animate, fadeIn: animate ? added : [])
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    // MARK: Layout

    private var tabWidth: CGFloat {
        let count = CGFloat(max(1, items.count))
        let fit = (bounds.width - Self.spacing * (count - 1)) / count
        return min(Self.maxTabWidth, max(Self.minTabWidth, fit)).rounded(.down)
    }

    private func slot(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: CGFloat(index) * (width + Self.spacing) - scrollOffset, y: 0, width: width, height: bounds.height)
    }

    private func layoutItems(animated: Bool, fadeIn: [TabItemView] = []) {
        guard !items.isEmpty else { return }
        let width = tabWidth
        let compact = width < Self.titleMinWidth
        // Keep the selected tab in view when the row overflows.
        let total = CGFloat(items.count) * (width + Self.spacing) - Self.spacing
        if total <= bounds.width {
            scrollOffset = 0
        } else if let selectedItem, let index = items.firstIndex(of: selectedItem) {
            let minX = CGFloat(index) * (width + Self.spacing)
            scrollOffset = min(max(scrollOffset, minX + width - bounds.width), minX)
            scrollOffset = min(max(0, scrollOffset), total - bounds.width)
        }
        for item in fadeIn {
            item.frame = slot(items.firstIndex(of: item) ?? 0, width: width)
            item.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.animationDuration : 0
            context.allowsImplicitAnimation = animated
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, item) in items.enumerated() where item !== drag?.item {
                item.isCompact = compact
                let frame = slot(index, width: width)
                if animated {
                    item.animator().frame = frame
                    item.animator().alphaValue = 1
                } else {
                    item.frame = frame
                    item.alphaValue = 1
                }
            }
        }
    }

    // MARK: Dragging

    fileprivate func beginDrag(_ item: TabItemView, with event: NSEvent) {
        drag = (item, convert(event.locationInWindow, from: nil).x, item.frame.minX, false)
    }

    fileprivate func continueDrag(with event: NSEvent) {
        guard var drag, let from = items.firstIndex(of: drag.item) else { return }
        let dx = convert(event.locationInWindow, from: nil).x - drag.startX
        if !drag.moved {
            guard abs(dx) > 4, items.count > 1 else { return }
            drag.moved = true
            // Keep the dragged tab above its neighbours.
            addSubview(drag.item, positioned: .above, relativeTo: nil)
        }
        self.drag = drag
        let width = tabWidth
        let maxX = CGFloat(items.count - 1) * (width + Self.spacing) - scrollOffset
        drag.item.frame.origin.x = min(max(-scrollOffset, drag.originX + dx), maxX)
        let center = drag.item.frame.midX + scrollOffset
        let to = min(items.count - 1, max(0, Int(center / (width + Self.spacing))))
        if to != from {
            items.insert(items.remove(at: from), at: to)
            layoutItems(animated: true)
        }
    }

    fileprivate func endDrag() {
        guard let drag else { return }
        self.drag = nil
        guard drag.moved, let index = items.firstIndex(of: drag.item) else { return }
        layoutItems(animated: true)
        delegate?.tabStrip(self, move: drag.item.tab, to: index)
    }
}

/// One tab: favicon or spinner, title, and a close button that replaces the
/// icon on hover.
final class TabItemView: NSView {
    let tab: Tab
    fileprivate weak var strip: TabStripView?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
            updateAppearance()
        }
    }
    /// Too narrow for a title: the icon sits in the middle.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            titleLabel.isHidden = isCompact
            // Off before on, so the two never hold at once.
            (isCompact ? iconLeading : iconCentered).isActive = false
            (isCompact ? iconCentered : iconLeading).isActive = true
            updateAppearance()
        }
    }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false { didSet { updateAppearance() } }
    private var iconLeading: NSLayoutConstraint!
    private var iconCentered: NSLayoutConstraint!

    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    private static let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = Self.closeImage
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"

        for view in [icon, spinner, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCentered = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            // On hover the close button takes the icon's place, as in Safari.
            closeButton.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let title = tab.displayTitle
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            toolTip = title
        }
        let image = tab.favicon ?? Self.globe
        if icon.image !== image { icon.image = image }
        icon.contentTintColor = .secondaryLabelColor
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isSelected ? .labelColor.withAlphaComponent(0.11)
            : isHovered ? .labelColor.withAlphaComponent(0.05) : .clear
        layer?.backgroundColor = fill.cgColor
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        // A compact tab only offers to close when it is the selected one, so a
        // pass of the mouse along a crowded row can't hit a close button.
        let showsClose = isHovered && (!isCompact || isSelected)
        closeButton.isHidden = !showsClose
        icon.isHidden = showsClose || tab.isLoading
        if tab.isLoading && !showsClose {
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

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        strip?.beginDrag(self, with: event)
    }

    override func mouseDragged(with event: NSEvent) { strip?.continueDrag(with: event) }
    override func mouseUp(with event: NSEvent) { strip?.endDrag() }

    // Middle click closes, as in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    // Clicks in the tab select it instead of dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeClicked() { onClose?() }
}
