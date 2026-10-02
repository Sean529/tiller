import AppKit

/// What a blank tab shows in place of an empty white page: the most visited
/// sites as tiles, the tabs closed lately as a short list, or a hint to use
/// the address bar when there is no history yet. It sits over the tab's
/// browser view while the tab is on about:blank.
final class StartPageView: NSView {
    /// Opens a tile's or row's URL, in the current tab or a new one.
    var onOpen: ((String, OpenDisposition) -> Void)?

    private let content = NSStackView()
    private let heading = StartPageView.heading("Frequently Visited")
    private let grid = NSGridView()
    private let closedHeading = StartPageView.heading("Recently Closed")
    private let closedList = NSStackView()
    private let emptyHint = NSStackView()
    private let glow = CAGradientLayer()
    /// Faint grain over the wash. A gradient this faint spans only a few
    /// of the display's levels, which show as bands; noise breaks them up.
    private let grain = GrainView()
    /// Bumped on every reload so a slow query can't show stale tiles.
    private var generation = 0
    /// The history the tiles were made from, so an unchanged history leaves
    /// them alone rather than querying again for every new tab.
    private var shownHistoryVersion = -1

    private static let columns = 4
    private static let limit = 8
    private static let closedLimit = 5
    /// The tiles' width, which the list under them matches.
    private static let width = CGFloat(columns) * SiteTile.width + CGFloat(columns - 1) * 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A faint wash of the accent color down from the top, so the page
        // reads as a place of its own rather than an empty document.
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 0.5, y: 0.45)
        layer?.addSublayer(glow)
        grain.frame = bounds
        grain.autoresizingMask = [.width, .height]
        addSubview(grain)

        grid.rowSpacing = 18
        grid.columnSpacing = 4

        closedList.orientation = .vertical
        closedList.alignment = .width
        closedList.spacing = 2

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let hint = NSTextField(labelWithString: "Search or enter a website in the address bar.")
        hint.font = .systemFont(ofSize: Theme.FontSize.body)
        hint.textColor = .secondaryLabelColor
        emptyHint.orientation = .vertical
        emptyHint.spacing = 14
        emptyHint.addArrangedSubview(icon)
        emptyHint.addArrangedSubview(hint)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.addArrangedSubview(Self.headingRow(heading))
        content.addArrangedSubview(grid)
        content.addArrangedSubview(Self.headingRow(closedHeading))
        content.addArrangedSubview(closedList)
        content.setCustomSpacing(30, after: grid)
        closedList.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        for view in [content, emptyHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                // A little above center reads as centered.
                view.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            ])
        }
        show([], closed: [])
        NotificationCenter.default.addObserver(
            self, selector: #selector(closedTabsChanged(_:)), name: .closedTabsDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A tab closed or came back while the page is up, so the list follows.
    @objc private func closedTabsChanged(_ notification: Notification) {
        if superview != nil { reload() }
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The heading starts where the first tile's square does.
    private static func headingRow(_ heading: NSTextField) -> NSView {
        let row = NSView()
        heading.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SiteTile.wellInset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            heading.topAnchor.constraint(equalTo: row.topAnchor),
            heading.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint = Theme.accent(dark ? 0.09 : 0.05)
        glow.colors = [tint.cgColor, NSColor.clear.cgColor]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }

    // Clicks on the background don't reach the page underneath.
    override func mouseDown(with event: NSEvent) {}

    /// Refreshes the tiles from history and the list from the closed tabs.
    /// The tiles are only rebuilt when the history changed since last time.
    func reload() {
        let closed = Array(SessionStore.shared.recentlyClosed.prefix(Self.closedLimit))
        let version = HistoryStore.shared.version
        if version == shownHistoryVersion {
            return show(shownSites, closed: closed)
        }
        generation += 1
        let generation = generation
        HistoryStore.shared.frequentSites(limit: Self.limit) { [weak self] sites in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.shownHistoryVersion = version
                    self.show(sites, closed: closed)
                }
            }
        }
    }

    /// The sites shown now, so the same ones again leave the tiles alone.
    private var shownSites: [FrequentSite] = []
    private var shownClosed: [SessionStore.SavedTab] = []

    private func show(_ sites: [FrequentSite], closed: [SessionStore.SavedTab]) {
        content.isHidden = sites.isEmpty && closed.isEmpty
        emptyHint.isHidden = !content.isHidden
        heading.superview?.isHidden = sites.isEmpty
        grid.isHidden = sites.isEmpty
        closedHeading.superview?.isHidden = closed.isEmpty
        closedList.isHidden = closed.isEmpty
        if closed != shownClosed {
            shownClosed = closed
            closedList.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for tab in closed {
                let row = ClosedTabRow(tab: tab) { [weak self] disposition in self?.onOpen?(tab.url, disposition) }
                closedList.addArrangedSubview(row)
            }
        }
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
        guard window != nil, !Theme.reduceMotion else { return }
        grid.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Duration.panel
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grid.animator().alphaValue = 1
        }
    }
}

/// A view that highlights under the mouse and acts on a click, with a middle
/// click opening in a background tab. Subclasses draw themselves.
private class ClickableView: NSView {
    let action: (OpenDisposition) -> Void
    private(set) var isHovered = false { didSet { needsDisplay = true } }
    private(set) var isPressed = false { didSet { needsDisplay = true } }

    init(action: @escaping (OpenDisposition) -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

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

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(.backgroundTab) }
    }

    override func accessibilityPerformPress() -> Bool {
        action(.currentTab)
        return true
    }

}

/// One site: its favicon, or its first letter, on a rounded square that
/// lifts a little under the mouse, with the site's name under it.
private final class SiteTile: ClickableView {
    static let width: CGFloat = 112
    static let wellSide: CGFloat = 70
    /// From a tile's edge to its square's.
    static let wellInset = (width - wellSide) / 2

    private let well = NSView()
    private let tint: NSColor

    init(site: FrequentSite, action: @escaping (OpenDisposition) -> Void) {
        tint = Self.color(for: site.host)
        super.init(action: action)
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
        name.font = .systemFont(ofSize: Theme.FontSize.secondary)
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
        setAccessibilityLabel(site.host)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A stable, soft color per site for letter tiles. Darker in light mode,
    /// where a bright yellow or green letter would barely show on the page.
    /// Nonisolated, so the color can resolve wherever AppKit asks for it.
    private nonisolated static func color(for host: String) -> NSColor {
        let hash = host.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hue: hue, saturation: 0.55, brightness: dark ? 0.85 : 0.7, alpha: 1)
        }
    }

    override func updateLayer() {
        guard let layer = well.layer else { return }
        layer.cornerRadius = Theme.Radius.tile
        layer.cornerCurve = .continuous
        layer.borderWidth = Theme.hairlineWidth
        layer.borderColor = Theme.hairline.cgColor
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        // The square lifts under the mouse and settles under a press, except
        // under Reduce Motion, where the fill alone shows it.
        let scale: CGFloat = Theme.reduceMotion ? 1 : isPressed ? 0.97 : isHovered ? 1.04 : 1
        withEasing {
            layer.backgroundColor = Theme.fill(alpha).cgColor
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    override func layout() {
        super.layout()
        // Scaling is about the middle of the square.
        well.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        well.layer?.position = CGPoint(x: well.frame.midX, y: well.frame.midY)
    }
}

/// One closed tab: its site's icon, then its title and address on one
/// line, which highlights as a row under the mouse.
private final class ClosedTabRow: ClickableView {
    init(tab: SessionStore.SavedTab, action: @escaping (OpenDisposition) -> Void) {
        super.init(action: action)
        let icon = FaviconView()
        // A site without a favicon shows the globe, as it does in the tab strip.
        icon.image = Theme.symbol("globe", size: Theme.Symbol.row, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        HistoryStore.shared.icon(for: tab.url) { [weak icon] png in
            guard let png, let image = NSImage(data: png) else { return }
            image.size = NSSize(width: 16, height: 16)
            DispatchQueue.main.async { MainActor.assumeIsolated { icon?.image = image } }
        }
        let title = NSTextField(labelWithString: tab.title.isEmpty ? HistoryStore.bare(tab.url) : tab.title)
        title.font = .systemFont(ofSize: Theme.FontSize.body)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let address = NSTextField(labelWithString: HistoryStore.bare(tab.url))
        address.font = .systemFont(ofSize: Theme.FontSize.secondary)
        address.textColor = .tertiaryLabelColor
        address.lineBreakMode = .byTruncatingTail
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, address])
        stack.spacing = 8
        stack.setCustomSpacing(10, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = tab.url
        setAccessibilityLabel(title.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill = Theme.fill(hovered: isHovered, pressed: isPressed)
        withEasing { layer?.backgroundColor = fill.cgColor }
    }
}

/// Noise over the wash: a tile of pixels at random, very low alphas,
/// repeated. White in dark mode and black in light mode, where white would
/// not show. Lets the mouse through to what is under it.
private final class GrainView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(patternImage: dark ? Self.whiteTile : Self.blackTile).setFill()
        dirtyRect.fill()
    }

    private static let whiteTile = tile(white: true)
    private static let blackTile = tile(white: false)

    private static func tile(white: Bool) -> NSImage {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt32 = 0x9E37_79B9
        for index in 0..<(side * side) {
            // A small linear congruential generator; the pattern only has to look random.
            state = state &* 1_664_525 &+ 1_013_904_223
            // Up to about 0.025 for white on a dark wash. Black on a light
            // one shows at a third of that; more reads as dirt.
            let alpha = UInt8(truncatingIfNeeded: state >> 24) / (white ? 40 : 120)
            // Premultiplied, so white has every channel at the alpha and
            // black has only the alpha.
            for channel in 0..<3 { pixels[index * 4 + channel] = white ? alpha : 0 }
            pixels[index * 4 + 3] = alpha
        }
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}
