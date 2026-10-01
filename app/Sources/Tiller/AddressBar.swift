import AppKit

/// A Liquid Glass capsule holding a lock for secure pages, the address field
/// and, at the end, the zoom and a key button that fills a saved login. It
/// is a titlebar accessory under the tabs, or a toolbar item when the tabs
/// are in the sidebar. While a page loads, the capsule fills with a faint
/// tint from the left, as in Safari.
final class AddressBarView: NSView {
    let field = AddressField()
    let keyButton = NSButton()
    /// The page's zoom, when it isn't 100%. Clicking it resets.
    let zoomButton = NSButton()
    /// Room left at each end of the capsule.
    var inset: CGFloat = 12 {
        didSet {
            capsuleLeading.constant = inset
            capsuleTrailing.constant = -inset
        }
    }

    private let statusIcon = NSImageView()
    /// The symbol `statusIcon` shows, so it is only made when it changes.
    private var statusSymbol = ""
    /// Whether the user is typing, when the icon says what Return would do.
    private var isEditing = false
    private let glass = NSGlassEffectView()
    private let progressFill = NSView()
    private var capsuleLeading: NSLayoutConstraint!
    private var capsuleTrailing: NSLayoutConstraint!
    /// Whether the tint is tracking a load, as opposed to finishing or hidden.
    private var showsLoad = false
    /// The capsule, for placing the suggestion list under it.
    var capsule: NSView { glass }

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.placeholderString = "Search or enter website"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Only Return navigates. Leaving the field must not load what it shows.
        field.cell?.sendsActionOnEndEditing = false

        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.imageScaling = .scaleNone

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

        // Hidden buttons give their room to the field.
        let buttons = NSStackView(views: [zoomButton, keyButton])
        buttons.spacing = 2
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 15
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        progressFill.wantsLayer = true
        progressFill.alphaValue = 0
        content.addSubview(progressFill)
        for view in [statusIcon, field, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        glass.contentView = content
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        capsuleLeading = glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        capsuleTrailing = glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            capsuleLeading,
            capsuleTrailing,
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),

            statusIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusIcon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -4),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keyButton.widthAnchor.constraint(equalToConstant: 20),
        ])
        field.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.isEditing = editing
            self.showStatus(of: self.field.url)
        }
        showStatus(of: "")
    }

    /// Shows the zoom badge for `factor`, or hides it at 100%.
    func showZoom(_ factor: Double) {
        let percent = Int((factor * 100).rounded())
        if percent != 100 { zoomButton.title = "\(percent)%" }
        zoomButton.isHidden = percent == 100
    }

    required init?(coder: NSCoder) { fatalError() }

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
        showStatus(of: url)
    }

    /// A lock for https, a warning for http, and a magnifying glass where
    /// there is no page yet or while typing, when Return searches or goes
    /// to what was typed rather than the page shown before.
    private func showStatus(of url: String) {
        let (symbol, description) = if isEditing {
            ("magnifyingglass", "Search")
        } else if url.hasPrefix("https://") {
            ("lock.fill", "Secure")
        } else if url.hasPrefix("http://") {
            ("exclamationmark.triangle", "Not Secure")
        } else if url.isEmpty || url == "about:blank" {
            ("magnifyingglass", "Search")
        } else {
            ("globe", "Page")
        }
        if statusSymbol != symbol {
            statusSymbol = symbol
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        }
        statusIcon.toolTip = !isEditing && url.hasPrefix("http") ? description : nil
    }
}

/// The address field. At rest it shows the whole URL with everything but the
/// site dimmed; a click selects it all, so typing replaces it.
final class AddressField: NSTextField {
    var url = "" {
        didSet { if !isEditing { showURL() } }
    }

    /// Called with true when typing starts and false when it ends.
    var onEditingChanged: ((Bool) -> Void)?

    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        stringValue = url == "about:blank" ? "" : url
        guard super.becomeFirstResponder() else {
            showURL()
            return false
        }
        currentEditor()?.selectAll(nil)
        onEditingChanged?(true)
        return true
    }

    /// The first click selects the whole URL, as in Safari. Left to the
    /// field editor, it would put the caret where the click landed.
    override func mouseDown(with event: NSEvent) {
        guard isEditing else {
            window?.makeFirstResponder(self)
            // Becoming first responder on a click can hand the click to the
            // field editor, which puts the caret where it landed, so select
            // now and again once that has settled.
            currentEditor()?.selectAll(nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.currentEditor()?.selectAll(nil) }
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return on input that goes nowhere ends editing only to start it
        // again, so check once things settle.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isEditing else { return }
                self.showURL()
                self.onEditingChanged?(false)
            }
        }
    }

    /// Escape: back to the page's URL, still editing.
    func revert() {
        stringValue = url == "about:blank" ? "" : url
        currentEditor()?.selectAll(nil)
    }

    private func showURL() {
        let shown = url == "about:blank" ? "" : url
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: shown, attributes: [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: Self.siteRange(in: shown))
        attributedStringValue = text
        toolTip = shown.isEmpty ? nil : shown
    }

    /// The host and port of a URL with `://`, else all of it.
    static func siteRange(in url: String) -> NSRange {
        let whole = NSRange(url.startIndex..., in: url)
        guard let scheme = url.range(of: "://") else { return whole }
        let end = url[scheme.upperBound...].firstIndex { "/?#".contains($0) } ?? url.endIndex
        return NSRange(scheme.upperBound..<end, in: url)
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
