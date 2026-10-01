import AppKit

/// The column at the left of the window when tabs are in a sidebar: a button
/// that collapses it to icons, then the tabs. It has no background of its
/// own, so it reads as one surface with the toolbar.
final class TabSidebarView: NSView {
    static let collapsedWidth: CGFloat = 52
    static let widthRange: ClosedRange<CGFloat> = 80...400
    static let defaultWidth: CGFloat = 220

    let collapseButton = NSButton()
    var isCollapsed = false {
        didSet {
            let label = isCollapsed ? "Expand Tabs" : "Collapse Tabs"
            collapseButton.toolTip = label
            // VoiceOver reads what a press does now, not what it did at launch.
            collapseButton.setAccessibilityLabel(label)
            needsLayout = true
        }
    }

    private weak var strip: TabStripView?
    private static let inset: CGFloat = 8
    private static let headerHeight: CGFloat = 36

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        collapseButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Collapse Tabs")
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .accessoryBarAction
        collapseButton.imagePosition = .imageOnly
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.toolTip = "Collapse Tabs"
        collapseButton.setAccessibilityLabel("Collapse Tabs")
        addSubview(collapseButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the tabs from wherever they were.
    func show(_ strip: TabStripView) {
        self.strip = strip
        addSubview(strip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 28
        collapseButton.frame = NSRect(
            x: isCollapsed ? ((bounds.width - size) / 2).rounded() : Self.inset + 2,
            y: (Self.headerHeight - size) / 2, width: size, height: size
        )
        guard let strip, strip.superview === self else { return }
        strip.frame = NSRect(
            x: Self.inset, y: Self.headerHeight, width: max(0, bounds.width - 2 * Self.inset),
            height: max(0, bounds.height - Self.headerHeight - Self.inset)
        )
    }
}

/// A split view whose dividers can go unseen, for panes that share a surface.
final class ChromeSplitView: NSSplitView {
    var hidesDividers = false {
        didSet { needsDisplay = true }
    }

    override var dividerColor: NSColor {
        hidesDividers ? .clear : super.dividerColor
    }
}
