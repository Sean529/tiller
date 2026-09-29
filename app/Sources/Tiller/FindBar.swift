import AppKit

/// Find in page: a glass capsule at the top right of the page with the search
/// text, the match count, previous/next buttons and a close button. Return
/// goes to the next match, Shift+Return the previous one, Escape closes.
final class FindBar: NSView, NSTextFieldDelegate {
    /// The search text changed. Empty text ends the search.
    var onChange: ((String) -> Void)?
    /// Go to the next match (true) or the previous one (false).
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let glass = NSGlassEffectView()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor

        field.placeholderString = "Find in page"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let closeButton = NSButton()
        for (button, symbol, tip, action) in [
            (previousButton, "chevron.up", "Previous Match (Shift+Return)", #selector(previous(_:))),
            (nextButton, "chevron.down", "Next Match (Return)", #selector(next(_:))),
            (closeButton, "xmark", "Done (Escape)", #selector(close(_:))),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.toolTip = tip
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }

        let row = NSStackView(views: [icon, field, countLabel, previousButton, nextButton, closeButton])
        row.spacing = 4
        row.setCustomSpacing(6, after: icon)
        row.setCustomSpacing(8, after: countLabel)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        glass.contentView = row
        glass.cornerRadius = 17
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.heightAnchor.constraint(equalToConstant: 34),
            glass.widthAnchor.constraint(equalToConstant: 340),
        ])
        showCount(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows "3 of 12" or "No matches", or nothing while there's no search.
    func showCount(_ result: (count: Int, active: Int)?) {
        let hasText = !field.stringValue.isEmpty
        switch result {
        case let (count, active)? where count > 0:
            countLabel.stringValue = "\(active) of \(count)"
            countLabel.textColor = .secondaryLabelColor
        case _? where hasText:
            countLabel.stringValue = "No matches"
            countLabel.textColor = .systemRed
        default:
            countLabel.stringValue = ""
        }
        let canStep = hasText && (result?.count ?? 0) > 0
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!backward)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    @objc private func previous(_ sender: Any?) { onStep?(false) }
    @objc private func next(_ sender: Any?) { onStep?(true) }
    @objc private func close(_ sender: Any?) { onClose?() }
}
