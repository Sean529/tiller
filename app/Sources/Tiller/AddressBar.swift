import AppKit

/// The row under the tabs: a Liquid Glass capsule holding the address field,
/// the reload/stop button and, on pages with a saved login, a key button that
/// fills it. Used as a titlebar accessory. While a page loads, the capsule
/// fills with a faint tint from the left, as in Safari.
final class AddressBarView: NSView {
    let field = AddressField()
    let reloadButton = NSButton()
    let keyButton = NSButton()
    /// The page's zoom, when it isn't 100%. Clicking it resets.
    let zoomButton = NSButton()
    private var fieldToReload: NSLayoutConstraint!
    private var fieldToZoom: NSLayoutConstraint!

    private let glass = NSGlassEffectView()
    private let progressFill = NSView()
    /// Whether the tint is tracking a load, as opposed to finishing or hidden.
    private var showsLoad = false
    private var isLoading = false
    /// The capsule, for placing the suggestion list under it.
    var capsule: NSView { glass }

    private static let reloadImage = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    private static let stopImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.placeholderString = "Search or enter website"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        // Only Return navigates. Leaving the field must not load what it shows.
        field.cell?.sendsActionOnEndEditing = false

        reloadButton.bezelStyle = .accessoryBarAction
        reloadButton.isBordered = false
        reloadButton.imagePosition = .imageOnly
        reloadButton.contentTintColor = .secondaryLabelColor
        applyLoading(false)

        keyButton.bezelStyle = .accessoryBarAction
        keyButton.isBordered = false
        keyButton.imagePosition = .imageOnly
        keyButton.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Fill Password")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        keyButton.contentTintColor = .secondaryLabelColor
        keyButton.toolTip = "Fill Saved Password"
        keyButton.isHidden = true

        zoomButton.bezelStyle = .accessoryBarAction
        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = .secondaryLabelColor
        zoomButton.toolTip = "Actual Size"
        zoomButton.isHidden = true

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 15
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        progressFill.wantsLayer = true
        progressFill.alphaValue = 0
        content.addSubview(progressFill)
        for view in [field, reloadButton, keyButton, zoomButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        glass.contentView = content
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let preferredWidth = glass.widthAnchor.constraint(equalToConstant: 720)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),
            glass.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            glass.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            preferredWidth,

            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            zoomButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -2),
            zoomButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 20),
            keyButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            keyButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keyButton.widthAnchor.constraint(equalToConstant: 20),
        ])
        fieldToReload = field.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -6)
        fieldToZoom = field.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -4)
        fieldToReload.isActive = true
    }

    /// Shows the zoom badge for `factor`, or hides it at 100%.
    func showZoom(_ factor: Double) {
        let percent = Int((factor * 100).rounded())
        let hidden = percent == 100
        if !hidden { zoomButton.title = "\(percent)%" }
        guard zoomButton.isHidden != hidden else { return }
        zoomButton.isHidden = hidden
        // Off before on, so the two never hold at once.
        (hidden ? fieldToZoom : fieldToReload).isActive = false
        (hidden ? fieldToReload : fieldToZoom).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        applyLoading(loading)
    }

    private func applyLoading(_ loading: Bool) {
        isLoading = loading
        reloadButton.image = loading ? Self.stopImage : Self.reloadImage
        reloadButton.toolTip = loading ? "Stop" : "Reload"
    }

    /// Moves the load tint to `progress` (0 to 1). When `loading` turns false
    /// the tint runs to the end and fades out. Without `animated`, as when
    /// switching tabs, it jumps straight to the new state.
    func setProgress(_ progress: Double, loading: Bool, animated: Bool = true) {
        guard let content = progressFill.superview else { return }
        let bounds = content.bounds
        let target = NSRect(x: 0, y: 0, width: bounds.width * min(1, max(0.08, progress)), height: bounds.height)
        progressFill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        let started = loading && !showsLoad
        showsLoad = loading
        if !animated {
            progressFill.frame = target
            progressFill.alphaValue = loading ? 1 : 0
        } else if loading {
            if started {
                // A new load starts from the left edge.
                progressFill.frame = NSRect(x: 0, y: 0, width: 0, height: bounds.height)
                progressFill.alphaValue = 1
            }
            guard target.width > progressFill.frame.width else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                progressFill.animator().frame = target
            }
        } else if progressFill.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                progressFill.animator().frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.showsLoad else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        self.progressFill.animator().alphaValue = 0
                    }
                }
            }
        }
    }

    /// Shows `url` unless the user is typing. Blank pages show the placeholder.
    func show(_ url: String) {
        field.url = url
    }
}

/// The address field. At rest it shows just the site, centered; while being
/// edited it shows the whole URL, selected, so typing replaces it.
final class AddressField: NSTextField {
    var url = "" {
        didSet { if !isEditing { showSite() } }
    }

    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        alignment = .natural
        stringValue = url == "about:blank" ? "" : url
        guard super.becomeFirstResponder() else {
            showSite()
            return false
        }
        // A click places the caret after this returns; select everything
        // afterwards so the first click selects the whole URL, as in Safari.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.currentEditor()?.selectAll(nil) }
        }
        return true
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return on input that goes nowhere ends editing only to start it
        // again, so check once things settle.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isEditing else { return }
                self.showSite()
            }
        }
    }

    /// Escape: back to the page's URL, still editing.
    func revert() {
        stringValue = url == "about:blank" ? "" : url
        currentEditor()?.selectAll(nil)
    }

    private func showSite() {
        alignment = .center
        stringValue = Self.site(of: url)
        toolTip = url.isEmpty || url == "about:blank" ? nil : url
    }

    /// The host without "www." for web pages; other URLs as they are.
    static func site(of url: String) -> String {
        url == "about:blank" ? "" : HistoryStore.host(of: url) ?? url
    }
}

/// Turns address bar input into a URL: a URL if it looks like one, else a
/// search with the engine chosen in Settings.
enum AddressInput {
    static func url(for input: String) -> String {
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return input
        }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let looksLikeHost = !input.contains(" ")
            && (host.contains(".") || host.hasPrefix("localhost") || host.contains(":"))
        if looksLikeHost {
            let scheme = host.hasPrefix("localhost") || host.hasPrefix("127.") ? "http" : "https"
            return "\(scheme)://\(input)"
        }
        return Settings.searchURL(for: input)
    }
}
