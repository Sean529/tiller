import AppKit

/// The row above the message field: a numbered button per open chat on the
/// left, and new tab, new chat and history buttons on the right.
final class AgentTabBar: NSView {
    static let height: CGFloat = 26

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewChat: (() -> Void)?
    /// Gets the history button, to show the list from.
    var onHistory: ((NSView) -> Void)?

    private let tabStack = NSStackView()
    private let newTabButton = AgentTabBar.iconButton("plus.square", "New Tab")
    private let newChatButton = AgentTabBar.iconButton("square.and.pencil", "New Chat")
    private let historyButton = AgentTabBar.iconButton("clock.arrow.circlepath", "Chat History")

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabStack.spacing = 6
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newChatButton.target = self
        newChatButton.action = #selector(newChat(_:))
        historyButton.target = self
        historyButton.action = #selector(history(_:))
        let buttons = NSStackView(views: [newTabButton, newChatButton, historyButton])
        buttons.spacing = 4
        for view in [tabStack, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: tabStack.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The new tab button shows only while there is room for another tab.
    func update(tabs: [(title: String, busy: Bool)], selected: Int, canAddTab: Bool) {
        while tabStack.arrangedSubviews.count > tabs.count { tabStack.arrangedSubviews.last?.removeFromSuperview() }
        while tabStack.arrangedSubviews.count < tabs.count {
            let index = tabStack.arrangedSubviews.count
            let button = TabNumberButton(number: index + 1)
            button.onSelect = { [weak self] in self?.onSelect?(index) }
            button.onClose = { [weak self] in self?.onClose?(index) }
            tabStack.addArrangedSubview(button)
        }
        for (index, (view, tab)) in zip(tabStack.arrangedSubviews, tabs).enumerated() {
            guard let button = view as? TabNumberButton else { continue }
            button.title = tab.title
            button.isBusy = tab.busy
            button.isSelected = index == selected
        }
        newTabButton.isHidden = !canAddTab
    }

    @objc private func newTab(_ sender: Any?) { onNewTab?() }
    @objc private func newChat(_ sender: Any?) { onNewChat?() }
    @objc private func history(_ sender: Any?) { onHistory?(historyButton) }

    private static func iconButton(_ symbol: String, _ title: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.toolTip = title
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
}

/// A tab's number in a rounded square, outlined in the accent color when
/// selected, with a dot while its agent works. Right-click to close it.
private final class TabNumberButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var title = "" {
        didSet {
            toolTip = title
            setAccessibilityLabel("Tab \(number): \(title)")
        }
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isBusy = false { didSet { busyDot.isHidden = !isBusy } }

    private let number: Int
    private let busyDot = NSView()
    private var isHovered = false { didSet { needsDisplay = true } }

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        wantsLayer = true
        let label = NSTextField(labelWithString: "\(number)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        busyDot.wantsLayer = true
        busyDot.layer?.cornerRadius = 3
        busyDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        busyDot.isHidden = true
        for view in [label, busyDot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AgentTabBar.height),
            heightAnchor.constraint(equalToConstant: AgentTabBar.height),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            busyDot.widthAnchor.constraint(equalToConstant: 6),
            busyDot.heightAnchor.constraint(equalToConstant: 6),
            busyDot.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            busyDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovered ? 0.1 : 0.05).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        busyDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close Tab", action: #selector(close(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func close(_ sender: Any?) { onClose?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

// MARK: History

/// The list of saved chats, newest first, that the history button shows.
/// A chat open in a tab says which; the selected tab's is marked. Right-click
/// a chat to delete it.
final class AgentHistoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let conversation: AgentConversation
        /// The tab it is open in.
        let tab: Int?
    }

    var onOpen: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private var items: [Item]
    /// The selected tab's chat.
    private let current: String
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No chats yet")
    private var scrollHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 48
    private static let width: CGFloat = 300

    init(items: [Item], current: String) {
        self.items = items
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = NSAttributedString(string: "CHATS", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
        let rule = NSBox()
        rule.boxType = .separator

        table.addTableColumn(NSTableColumn(identifier: .init("chat")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        let view = NSView()
        for subview in [header, rule, scroll, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = view
        reload(items)
    }

    /// Up to about seven chats show before the list scrolls.
    func reload(_ items: [Item]) {
        self.items = items
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollHeight.constant = items.isEmpty ? 56 : min(CGFloat(items.count), 7.5) * Self.rowHeight
        preferredContentSize = view.fittingSize
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = HistoryRowView()
        view.isCurrent = items[row].conversation.id == current
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let isCurrent = item.conversation.id == current
        let subtitle = item.tab.map { "Open in tab \($0 + 1)" } ?? Self.dateText(item.conversation.updated)
        return HistoryCellView(
            title: item.conversation.title,
            subtitle: subtitle + " · " + item.conversation.kind.displayName,
            logo: item.conversation.kind.logo(size: 18),
            isCurrent: isCurrent
        )
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onOpen?(items[row].conversation.id)
    }

    @objc private func deleteClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onDelete?(items[row].conversation.id)
    }

    /// The time today, "Yesterday", then the date, with the year if not this one.
    private static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

/// A row of the history list: highlighted on hover, and marked with an
/// accent bar at its edge for the selected tab's chat.
private final class HistoryRowView: NSTableRowView {
    var isCurrent = false
    private var isHovered = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        if isCurrent || isHovered {
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.08 : 0.05).setFill()
            bounds.fill()
        }
        if isCurrent {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The agent's logo, or a chat bubble icon without one, beside the chat's
/// title and where or when it was.
private final class HistoryCellView: NSView {
    init(title: String, subtitle: String, logo: NSImage?, isCurrent: Bool) {
        super.init(frame: .zero)
        let icon = NSImageView(image: logo ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
        if logo == nil { icon.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = isCurrent ? .secondaryLabelColor : .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }
}
