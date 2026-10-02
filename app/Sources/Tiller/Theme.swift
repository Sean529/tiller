import AppKit

/// The values the chrome shares, so a hover, a corner or a caption reads the
/// same in the tab strip, the start page, the popovers and the agent panel.
/// Colors stay semantic system colors with an alpha on top, so they follow
/// light and dark mode on their own. The accent is the one chosen in
/// Settings, which `accentColor` reads each time it is drawn.
enum Theme {
    // MARK: Fills

    /// Alphas of `labelColor` for a surface's resting, hovered, pressed and
    /// selected states.
    enum Fill {
        static let rest: CGFloat = 0.05
        static let hover: CGFloat = 0.08
        static let pressed: CGFloat = 0.12
        static let selected: CGFloat = 0.11
    }

    /// Alphas of `controlAccentColor` for tinted surfaces.
    enum Accent {
        /// A badge or a light wash.
        static let soft: CGFloat = 0.14
        /// The selected row of a list.
        static let selected: CGFloat = 0.18
        /// The selected row under the mouse.
        static let selectedHover: CGFloat = 0.26
        /// The user's message bubble.
        static let bubble: CGFloat = 0.2
        /// The outline of a selected surface.
        static let outline: CGFloat = 0.45
    }

    /// `labelColor` at `alpha`.
    static func fill(_ alpha: CGFloat) -> NSColor { .labelColor.withAlphaComponent(alpha) }

    /// The fill for a row or tile in the given state, or clear at rest.
    static func fill(hovered: Bool, pressed: Bool = false, selected: Bool = false) -> NSColor {
        if pressed { return fill(Fill.pressed) }
        if selected { return fill(Fill.selected) }
        if hovered { return fill(Fill.hover) }
        return .clear
    }

    /// The accent chosen in Settings, resolved whenever it is drawn, so a
    /// color set once still follows a change. Nonisolated, so it can resolve
    /// wherever AppKit asks for it.
    nonisolated static let accentColor = accentColor(alpha: 1)

    /// The accent at `alpha`.
    static func accent(_ alpha: CGFloat) -> NSColor { accentColor(alpha: alpha) }

    private nonisolated static func accentColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance {
                color = Settings.accentTheme.color.usingColorSpace(.sRGB) ?? color
            }
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
        }
    }

    /// The solid fill of a highlighted row: the system's, or the chosen accent.
    static var selectionColor: NSColor {
        Settings.accentTheme == .system ? .selectedContentBackgroundColor : accentColor
    }

    /// A one-point line between surfaces.
    static var hairline: NSColor { .separatorColor }

    // MARK: Shape

    enum Radius {
        /// Tables, boxes and badges.
        static let small: CGFloat = 6
        /// Rows in lists, tool rows, code blocks and thumbnails.
        static let row: CGFloat = 8
        /// Cards: the page, error boxes.
        static let card: CGFloat = 10
        /// Floating plates, bubbles and chips.
        static let plate: CGFloat = 14
        /// The start page's site tiles.
        static let tile: CGFloat = 18
    }

    static let hairlineWidth: CGFloat = 1

    // MARK: Type

    enum FontSize {
        /// Captions, counts and uppercase headers.
        static let caption: CGFloat = 11
        /// Secondary lines: URLs, dates, hints.
        static let secondary: CGFloat = 12
        /// Row titles and messages.
        static let body: CGFloat = 13
        /// Panel titles.
        static let title: CGFloat = 15
    }

    /// The uppercase header of a popover section, such as DOWNLOADS or CHATS.
    static func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: FontSize.caption, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
    }

    // MARK: Icons

    /// SF Symbol point sizes.
    enum Symbol {
        /// Beside text in a field or a row.
        static let inline: CGFloat = 11
        /// A row's leading icon.
        static let row: CGFloat = 12
        /// A toolbar or bar button.
        static let bar: CGFloat = 14
        /// A panel's primary action, or an empty state.
        static let hero: CGFloat = 22
    }

    /// Square sizes of icon-only buttons.
    enum ButtonSize {
        /// Beside text, as in the find bar.
        static let inline: CGFloat = 22
        /// In a bar of buttons.
        static let bar: CGFloat = 26
    }

    /// An SF Symbol image at a shared size.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// An icon-only button with no bezel, as in bars and rows. `label` is
    /// both the tooltip and what VoiceOver reads.
    static func iconButton(_ name: String, label: String, size: CGFloat = Symbol.bar, frame: CGFloat = ButtonSize.bar) -> NSButton {
        let button = NSButton()
        button.image = symbol(name, size: size, label: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: frame),
            button.heightAnchor.constraint(equalToConstant: frame),
        ])
        return button
    }

    /// The one close glyph, for tabs, bars and chips.
    static func closeImage(size: CGFloat = 9, label: String) -> NSImage? {
        symbol("xmark", size: size, weight: .bold, label: label)
    }

    // MARK: Layout

    enum RowHeight {
        /// A suggestion.
        static let compact: CGFloat = 30
        /// A tab in the sidebar, a closed tab on the start page.
        static let standard: CGFloat = 34
        /// Two lines: a download, a chat in history.
        static let twoLine: CGFloat = 48
    }

    enum Padding {
        static let tight: CGFloat = 8
        static let row: CGFloat = 10
        static let panel: CGFloat = 12
        static let section: CGFloat = 14
        static let sheet: CGFloat = 20
    }

    /// The width of popovers hanging off the toolbar and the agent bar.
    static let popoverWidth: CGFloat = 320
    /// The height a list keeps for an empty-state label.
    static let emptyListHeight: CGFloat = 56
    /// A busy indicator's dot.
    static let busyDot: CGFloat = 6

    // MARK: Motion

    enum Duration {
        /// A fill fading under the mouse.
        static let quick: TimeInterval = 0.12
        /// The default ease for layer changes.
        static let standard: TimeInterval = 0.15
        /// Tabs sliding to a new order.
        static let slide: TimeInterval = 0.2
        /// A panel opening or closing.
        static let panel: TimeInterval = 0.25
    }

    // MARK: Appearance

    /// Sets light or dark from Settings for the whole app, which Chromium
    /// passes on to pages as `prefers-color-scheme`.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = Settings.appearance.appearance
    }

    /// Redraws every window after the accent changes. Views pick their
    /// colors in `updateLayer` or `draw`, which a change of accent alone
    /// would not call again, unlike a change of appearance.
    @MainActor
    static func redrawAll() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        for window in NSApp.windows {
            if let frame = window.contentView?.superview { mark(frame) } else if let content = window.contentView { mark(content) }
        }
    }

    // MARK: Accessibility

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// The outline a filled selection gets under Increase Contrast, where a
    /// faint fill alone would not show.
    static func selectionOutline(selected: Bool) -> NSColor {
        increaseContrast && selected ? .labelColor.withAlphaComponent(Accent.outline) : .clear
    }
}

/// Runs `changes` to layer-backed views so their layers ease to the new
/// values over `duration`, instead of snapping as they do by default. Under
/// Reduce Motion the change lands at once.
@MainActor
func withEasing(_ duration: TimeInterval = Theme.Duration.standard, _ changes: () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = Theme.reduceMotion ? 0 : duration
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        changes()
    }
}

extension NSFont {
    /// The same font in the rounded design, where the system has one.
    var rounded: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
