import AppKit

/// History suggestions under the address bar while the user types. Up and
/// Down move through them, Return opens the highlighted one, Escape closes the
/// list. When the best match's address starts with what was typed, it is
/// highlighted from the start, so Return goes there instead of searching.
@MainActor
final class AddressSuggestions: NSObject, NSTextFieldDelegate {
    /// Opens a suggestion's URL, in the current tab or a new one.
    var onOpen: ((String, OpenDisposition) -> Void)?

    private let addressBar: AddressBarView
    private let panel = SuggestionsPanel()
    private let list = NSStackView()
    /// What the rows open: a search for the text, then the history pages.
    private var rows: [Suggestion] = []
    private var highlighted: Int?
    /// Bumped on every keystroke so a slow query can't show stale results.
    private var generation = 0

    private static let limit = 7
    private static let rowHeight = Theme.RowHeight.compact
    private static let inset: CGFloat = 6

    enum Suggestion {
        /// A search for the typed text, or the site it names.
        case input(String)
        case page(HistoryPage)

        var url: String {
            switch self {
            case .input(let text): AddressInput.url(for: text)
            case .page(let page): page.url
            }
        }
    }

    init(addressBar: AddressBarView) {
        self.addressBar = addressBar
        super.init()
        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .width
        let background = SuggestionsBackground()
        background.material = .popover
        // Blurs what is behind the panel, the page and the toolbar, and stays
        // lit though the panel is never key.
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.plate
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.inset),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.inset),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.inset),
        ])
        panel.contentView = background
        addressBar.field.delegate = self
    }

    var isShown: Bool { panel.isVisible }

    func hide() {
        generation += 1
        highlighted = nil
        shownPages = []
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
        // The row for the text itself follows every keystroke, over the
        // pages found for the last one; the ones for this come after.
        show(shownPages, for: text)
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
        guard panel.isVisible else {
            // Escape with no list up puts the page's URL back, as in Safari.
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            addressBar.field.revert()
            return true
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(rows.count - 1, (highlighted ?? 0) + 1))
        case #selector(NSResponder.moveUp(_:)):
            highlight(max(0, (highlighted ?? 0) - 1))
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        case #selector(NSResponder.insertNewline(_:)):
            guard let index = highlighted, rows.indices.contains(index) else {
                hide()
                return false
            }
            open(index, .returnKey(OpenDisposition.currentFlags))
        default:
            return false
        }
        return true
    }

    // MARK: List

    /// The first row is the text itself, as a search or a site, and starts
    /// highlighted, so Return does what the address bar would anyway. When
    /// the best match's address starts with the text, that row is
    /// highlighted instead, as Safari does.
    /// The history pages the rows show, kept for the next keystroke.
    private var shownPages: [HistoryPage] = []

    private func show(_ pages: [HistoryPage], for text: String) {
        shownPages = pages
        rows = [.input(text)] + pages.map(Suggestion.page)
        guard let window = addressBar.window else { return hide() }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, suggestion) in rows.enumerated() {
            let row = SuggestionRow(suggestion, typed: text)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.onHover = { [weak self] in self?.highlight(index) }
            row.onClick = { [weak self] disposition in self?.open(index, disposition) }
            list.addArrangedSubview(row)
        }
        let host = pages.first.map { HistoryStore.bare($0.url).lowercased() } ?? ""
        highlight(!host.isEmpty && host.hasPrefix(text.lowercased()) ? 1 : 0)

        let capsule = addressBar.capsule
        let frame = window.convertToScreen(capsule.convert(capsule.bounds, to: nil))
        let height = CGFloat(rows.count) * Self.rowHeight + 2 * Self.inset
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY - 6 - height, width: frame.width, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func highlight(_ index: Int?) {
        highlighted = index
        for (offset, row) in list.arrangedSubviews.enumerated() {
            (row as? SuggestionRow)?.isHighlighted = offset == index
        }
    }

    private func open(_ index: Int, _ disposition: OpenDisposition) {
        guard rows.indices.contains(index) else { return }
        let url = rows[index].url
        hide()
        onOpen?(url, disposition)
    }
}

/// The list's plate: a popover's material with a hairline around it, like
/// the glass of the address bar it hangs from.
private final class SuggestionsBackground: NSVisualEffectView {
    // A material view need not call updateLayer, so the border is set here
    // and again when the appearance changes the separator's color.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        guard let layer else { return }
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.cgColor
        }
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

/// One suggestion: for a page, its site's favicon, or a clock without one,
/// the page's title with the typed text in bold where it matches, then its
/// address in grey; for the typed text, a magnifying glass or globe and
/// what Return would do with it. The highlighted row takes the system's
/// selection colors, so it follows the accent color and contrast settings.
private final class SuggestionRow: NSView {
    var onHover: (() -> Void)?
    var onClick: ((OpenDisposition) -> Void)?

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            title.attributedStringValue = Self.highlighting(titleText, typed, color: isHighlighted ? .alternateSelectedControlTextColor : .labelColor)
            url.textColor = isHighlighted ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            if !showsFavicon { icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor }
        }
    }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    private let icon = FaviconView()
    private let showsFavicon: Bool
    private let title = NSTextField(labelWithString: "")
    private let url = NSTextField(labelWithString: "")
    private let titleText: String
    private let typed: String

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        Theme.symbol(name, size: Theme.Symbol.row, weight: .regular, label: description)
    }

    init(_ suggestion: AddressSuggestions.Suggestion, typed: String) {
        self.typed = typed
        var favicon: NSImage?
        var symbol: NSImage?
        var address = ""
        var tip = ""
        switch suggestion {
        case .page(let page):
            titleText = page.displayTitle
            address = HistoryStore.bare(page.url)
            favicon = page.icon.flatMap(NSImage.init(data:))
            symbol = Self.symbol("clock", "History")
            tip = page.url
        case .input(let text):
            let url = AddressInput.url(for: text)
            let isSearch = url == Settings.searchURL(for: text)
            titleText = text
            let engine = Settings.searchEngine
            address = isSearch ? (engine == .custom ? "Search" : "Search \(engine.displayName)") : HistoryStore.bare(url)
            symbol = Self.symbol(isSearch ? "magnifyingglass" : "globe", isSearch ? "Search" : "Website")
            tip = url
        }
        showsFavicon = favicon != nil
        super.init(frame: .zero)
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(address.isEmpty ? titleText : "\(titleText), \(address)")
        if let favicon {
            favicon.size = NSSize(width: 16, height: 16)
            icon.image = favicon
        } else {
            icon.image = symbol
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.attributedStringValue = Self.highlighting(titleText, typed, color: .labelColor)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        url.stringValue = address
        url.font = .systemFont(ofSize: Theme.FontSize.secondary)
        url.textColor = .secondaryLabelColor
        url.lineBreakMode = .byTruncatingTail
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, url])
        stack.spacing = 8
        stack.setCustomSpacing(10, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `text` with the first run matching `typed` in bold, case aside.
    private static func highlighting(_ text: String, _ typed: String, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.body), .foregroundColor: color,
        ])
        if !typed.isEmpty, let range = text.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) {
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .semibold), range: NSRange(range, in: text))
        }
        return result
    }

    // The row draws its own selection, so its text stays in plain colors
    // over the material rather than blending into it, as white on the
    // accent fill would.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row)
        Theme.selectionColor.setFill()
        path.fill()
        // A press shades the highlight, as it does a tile or a row elsewhere.
        if isPressed {
            Theme.fill(Theme.Fill.pressed).setFill()
            path.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    // On release, as buttons do, so a slip of the mouse can be taken back.
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(.click(event.modifierFlags)) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(.backgroundTab) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(.currentTab)
        return true
    }
}
