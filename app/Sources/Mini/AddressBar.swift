import AppKit

/// The row under the tabs: a Liquid Glass capsule holding the address field
/// and the reload/stop button. Used as a titlebar accessory.
final class AddressBarView: NSView {
    let field = NSTextField()
    let reloadButton = NSButton()

    private let glass = NSGlassEffectView()

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

        reloadButton.bezelStyle = .accessoryBarAction
        reloadButton.isBordered = false
        reloadButton.imagePosition = .imageOnly
        setLoading(false)

        let content = NSView()
        for view in [field, reloadButton] as [NSView] {
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
            field.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        reloadButton.image = NSImage(
            systemSymbolName: loading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: loading ? "Stop" : "Reload"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        reloadButton.toolTip = loading ? "Stop" : "Reload"
    }

    /// Shows `url` unless the user is typing. Blank pages show the placeholder.
    func show(_ url: String) {
        guard field.currentEditor() == nil else { return }
        field.stringValue = url == "about:blank" ? "" : url
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
