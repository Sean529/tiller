import AppKit

/// What a blank tab shows in place of an empty white page: the most visited
/// sites as tiles, or a hint to use the address bar when there is no history
/// yet. It sits over the tab's browser view while the tab is on about:blank.
final class StartPageView: NSView {
    /// Opens a tile's URL.
    var onOpen: ((String) -> Void)?

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

        grid.rowSpacing = 14
        grid.columnSpacing = 6

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

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.addArrangedSubview(heading)
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

    private func show(_ sites: [FrequentSite]) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        content.isHidden = sites.isEmpty
        emptyHint.isHidden = !sites.isEmpty
        let tiles = sites.map { site in
            SiteTile(site: site) { [weak self] in self?.onOpen?(site.url) }
        }
        for start in stride(from: 0, to: tiles.count, by: Self.columns) {
            let row = Array(tiles[start..<min(start + Self.columns, tiles.count)])
            grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: Self.columns - row.count))
        }
    }
}

/// One site: its favicon, or its first letter, on a rounded square, with the
/// site's name under it.
private final class SiteTile: NSView {
    private let action: () -> Void
    private let well = NSView()
    private let tint: NSColor
    private var isHovered = false { didSet { needsDisplay = true } }

    init(site: FrequentSite, action: @escaping () -> Void) {
        self.action = action
        tint = Self.color(for: site.host)
        super.init(frame: .zero)
        wantsLayer = true
        well.wantsLayer = true

        let glyph: NSView
        if let data = site.icon, let image = NSImage(data: data) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 30).isActive = true
            view.heightAnchor.constraint(equalToConstant: 30).isActive = true
            glyph = view
        } else {
            let letter = NSTextField(labelWithString: site.host.first.map { String($0).uppercased() } ?? "?")
            letter.font = .systemFont(ofSize: 24, weight: .semibold)
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
            widthAnchor.constraint(equalToConstant: 108),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.centerXAnchor.constraint(equalTo: centerXAnchor),
            well.widthAnchor.constraint(equalToConstant: 64),
            well.heightAnchor.constraint(equalToConstant: 64),
            glyph.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 7),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        well.layer?.cornerRadius = 16
        well.layer?.cornerCurve = .continuous
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.06).cgColor
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
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
