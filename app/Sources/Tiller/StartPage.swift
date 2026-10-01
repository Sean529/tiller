import AppKit

/// What a blank tab shows in place of an empty white page: the most visited
/// sites as tiles, or a hint to use the address bar when there is no history
/// yet. It sits over the tab's browser view while the tab is on about:blank.
final class StartPageView: NSView {
    /// Opens a tile's URL, in the current tab or a new one.
    var onOpen: ((String, OpenDisposition) -> Void)?

    private let content = NSStackView()
    private let heading = NSTextField(labelWithString: "Frequently Visited")
    private let grid = NSGridView()
    private let emptyHint = NSStackView()
    /// Bumped on every reload so a slow query can't show stale tiles.
    private var generation = 0

    private static let columns = 4
    private static let limit = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        grid.rowSpacing = 18
        grid.columnSpacing = 4

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let hint = NSTextField(labelWithString: "Search or enter a website in the address bar.")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor
        emptyHint.orientation = .vertical
        emptyHint.spacing = 14
        emptyHint.addArrangedSubview(icon)
        emptyHint.addArrangedSubview(hint)

        // The heading starts where the first tile's square does.
        let headingRow = NSView()
        heading.translatesAutoresizingMaskIntoConstraints = false
        headingRow.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor, constant: SiteTile.wellInset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: headingRow.trailingAnchor),
            heading.topAnchor.constraint(equalTo: headingRow.topAnchor),
            heading.bottomAnchor.constraint(equalTo: headingRow.bottomAnchor),
        ])

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.addArrangedSubview(headingRow)
        content.addArrangedSubview(grid)

        for view in [content, emptyHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                // A little above center reads as centered.
                view.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            ])
        }
        show([])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // Clicks on the background don't reach the page underneath.
    override func mouseDown(with event: NSEvent) {}

    /// Refreshes the tiles from history.
    func reload() {
        generation += 1
        let generation = generation
        HistoryStore.shared.frequentSites(limit: Self.limit) { [weak self] sites in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.show(sites)
                }
            }
        }
    }

    /// The sites shown now, so the same ones again leave the tiles alone.
    private var shownSites: [FrequentSite] = []

    private func show(_ sites: [FrequentSite]) {
        content.isHidden = sites.isEmpty
        emptyHint.isHidden = !sites.isEmpty
        guard sites != shownSites else { return }
        shownSites = sites
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        let tiles = sites.map { site in
            SiteTile(site: site) { [weak self] disposition in self?.onOpen?(site.url, disposition) }
        }
        for start in stride(from: 0, to: tiles.count, by: Self.columns) {
            let row = Array(tiles[start..<min(start + Self.columns, tiles.count)])
            grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: Self.columns - row.count))
        }
        // Tiles arrive a moment after the page, so they fade in rather than pop.
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        grid.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grid.animator().alphaValue = 1
        }
    }
}

/// One site: its favicon, or its first letter, on a rounded square, with the
/// site's name under it.
private final class SiteTile: NSView {
    static let width: CGFloat = 112
    static let wellSide: CGFloat = 68
    /// From a tile's edge to its square's.
    static let wellInset = (width - wellSide) / 2

    private let action: (OpenDisposition) -> Void
    private let well = NSView()
    private let tint: NSColor
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(site: FrequentSite, action: @escaping (OpenDisposition) -> Void) {
        self.action = action
        tint = Self.color(for: site.host)
        super.init(frame: .zero)
        wantsLayer = true
        well.wantsLayer = true

        let glyph: NSView
        if let data = site.icon, let image = NSImage(data: data) {
            let view = FaviconView()
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 32).isActive = true
            view.heightAnchor.constraint(equalToConstant: 32).isActive = true
            glyph = view
        } else {
            let letter = NSTextField(labelWithString: site.host.first.map { String($0).uppercased() } ?? "?")
            letter.font = .systemFont(ofSize: 26, weight: .semibold).rounded
            letter.textColor = tint
            glyph = letter
        }
        let name = NSTextField(labelWithString: site.host)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail

        for view in [well, glyph, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(well)
        well.addSubview(glyph)
        addSubview(name)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.centerXAnchor.constraint(equalTo: centerXAnchor),
            well.widthAnchor.constraint(equalToConstant: Self.wellSide),
            well.heightAnchor.constraint(equalToConstant: Self.wellSide),
            glyph.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = site.title.isEmpty ? site.url : "\(site.title)\n\(site.url)"
        setAccessibilityRole(.button)
        setAccessibilityLabel(site.host)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A stable, soft color per site for letter tiles.
    private static func color(for host: String) -> NSColor {
        let hash = host.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.55, brightness: 0.85, alpha: 1)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        well.layer?.cornerRadius = 18
        well.layer?.cornerCurve = .continuous
        let alpha = isPressed ? 0.16 : isHovered ? 0.11 : 0.06
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        well.layer?.borderWidth = 1
        well.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(.click(event.modifierFlags)) }
    }

    /// A middle click opens the site in a tab behind this one.
    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(.backgroundTab) }
    }

    override func accessibilityPerformPress() -> Bool {
        action(.currentTab)
        return true
    }
}

private extension NSFont {
    /// The same font in the rounded design, where the system has one.
    var rounded: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
