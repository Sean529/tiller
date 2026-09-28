import AppKit

/// History suggestions under the address bar while the user types. Up and
/// Down move through them, Return opens the highlighted one, Escape closes the
/// list. When the best match's address starts with what was typed, it is
/// highlighted from the start, so Return goes there instead of searching.
@MainActor
final class AddressSuggestions: NSObject, NSTextFieldDelegate {
    /// Opens a suggestion's URL.
    var onOpen: ((String) -> Void)?

    private let addressBar: AddressBarView
    private let panel = SuggestionsPanel()
    private let list = NSStackView()
    private var pages: [HistoryPage] = []
    private var highlighted: Int?
    /// Bumped on every keystroke so a slow query can't show stale results.
    private var generation = 0

    private static let limit = 8
    private static let rowHeight: CGFloat = 28

    init(addressBar: AddressBarView) {
        self.addressBar = addressBar
        super.init()
        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .width
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: 5),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 5),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -5),
        ])
        panel.contentView = background
        addressBar.field.delegate = self
    }

    var isShown: Bool { panel.isVisible }

    func hide() {
        generation += 1
        highlighted = nil
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let text = addressBar.field.stringValue.trimmingCharacters(in: .whitespaces)
        generation += 1
        guard !text.isEmpty else { return hide() }
        let generation = generation
        HistoryStore.shared.search(text, limit: Self.limit) { [weak self] pages in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.addressBar.field.currentEditor() != nil else { return }
                    self.show(pages, for: text)
                }
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hide()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard panel.isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(pages.count - 1, (highlighted ?? -1) + 1))
        case #selector(NSResponder.moveUp(_:)):
            highlight(highlighted.flatMap { $0 > 0 ? $0 - 1 : nil })
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        case #selector(NSResponder.insertNewline(_:)):
            guard let index = highlighted, pages.indices.contains(index) else {
                hide()
                return false
            }
            open(index)
        default:
            return false
        }
        return true
    }

    // MARK: List

    private func show(_ pages: [HistoryPage], for text: String) {
        self.pages = pages
        guard !pages.isEmpty, let window = addressBar.window else { return hide() }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, page) in pages.enumerated() {
            let row = SuggestionRow(page: page)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.onHover = { [weak self] in self?.highlight(index) }
            row.onClick = { [weak self] in self?.open(index) }
            list.addArrangedSubview(row)
        }
        let host = HistoryStore.bare(pages[0].url).lowercased()
        highlight(host.hasPrefix(text.lowercased()) ? 0 : nil)

        let capsule = addressBar.capsule
        let frame = window.convertToScreen(capsule.convert(capsule.bounds, to: nil))
        let height = CGFloat(pages.count) * Self.rowHeight + 10
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY - 4 - height, width: frame.width, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func highlight(_ index: Int?) {
        highlighted = index
        for (offset, row) in list.arrangedSubviews.enumerated() {
            (row as? SuggestionRow)?.isHighlighted = offset == index
        }
    }

    private func open(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        let url = pages[index].url
        hide()
        onOpen?(url)
    }
}

/// A borderless panel that never takes key status, so the address field keeps
/// the keyboard while the list is up.
private final class SuggestionsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A page's title, then its address in grey.
private final class SuggestionRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    init(page: HistoryPage) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: page.displayTitle)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let url = NSTextField(labelWithString: HistoryStore.bare(page.url))
        url.font = .systemFont(ofSize: 12)
        url.textColor = .secondaryLabelColor
        url.lineBreakMode = .byTruncatingTail
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, url])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = page.url
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
