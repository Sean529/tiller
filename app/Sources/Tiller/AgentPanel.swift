import AppKit
import Quartz

@MainActor
protocol AgentPanelDelegate: AnyObject {
    /// The selected tab, described for the agent at the start of each message.
    func agentPanelContext(_ panel: AgentPanelView) -> String
}

/// The side panel: pick an agent and chat with it, in up to a few tabs, each
/// with its own agent. A bar above the message field switches tabs, opens
/// new ones and past chats. The open tabs come back at the next launch.
/// Like the tab sidebar it has no background of its own, so it reads as one
/// surface with the toolbar.
final class AgentPanelView: NSView {
    weak var delegate: AgentPanelDelegate?
    /// Called when any chat starts or stops working.
    var onBusyChange: ((Bool) -> Void)?
    /// Whether any chat's agent is working.
    private(set) var isBusy = false {
        didSet { if isBusy != oldValue { onBusyChange?(isBusy) } }
    }

    /// The message being written in the selected tab.
    var input: NSView { active.input }

    private let agentPicker = NSPopUpButton()
    private let status = StatusPill()
    private let chatArea = NSView()
    private let tabBar = AgentTabBar()
    private var chats: [AgentChatView] = []
    private var activeIndex = 0
    private var active: AgentChatView { chats[activeIndex] }
    private var historyPopover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        restoreTabs()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabLimitChanged(_:)), name: .agentTabsDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The panel is on screen: have the selected chat's CLI looked up now,
    /// so the first message doesn't wait on a login shell.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        AgentEnvironment.warmUp(active.kind)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isHiddenOrHasHiddenAncestor { AgentEnvironment.warmUp(active.kind) }
    }

    /// Ends every tab's agent and saves the chats. Called when the window closes.
    func shutDown() {
        saveTabs()
        chats.forEach { $0.shutDown() }
        AgentHistoryStore.shared.flush()
        AgentHistoryStore.shared.waitForWrites()
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Layout

    private func build() {
        for kind in AgentKind.allCases {
            agentPicker.addItem(withTitle: kind.displayName)
            agentPicker.lastItem?.representedObject = kind.rawValue
            agentPicker.lastItem?.image = kind.logo(size: 16)
        }
        agentPicker.isBordered = false
        agentPicker.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        agentPicker.toolTip = "Agent for this chat"
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged(_:))

        tabBar.onSelect = { [weak self] index in self?.select(index, focus: true) }
        tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onNewChat = { [weak self] in self?.newChat() }
        tabBar.onHistory = { [weak self] button in self?.showHistory(from: button) }
        tabBar.onTools = { [weak self] button in self?.showTools(from: button) }
        tabBar.onSchedules = { (NSApp.delegate as? AppDelegate)?.showScheduledSettings() }

        for view in [agentPicker, status, chatArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            agentPicker.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            agentPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: agentPicker.trailingAnchor, constant: 4),
            status.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            chatArea.topAnchor.constraint(equalTo: agentPicker.bottomAnchor, constant: 8),
            chatArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            chatArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            chatArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Tabs

    /// Last time's tabs, up to the limit. A chat since deleted opens empty.
    private func restoreTabs() {
        let store = AgentHistoryStore.shared
        for id in store.openTabs.prefix(Settings.agentTabs) {
            add(AgentChatView(conversation: id.isEmpty ? nil : store.conversation(id)))
        }
        if chats.isEmpty { add(AgentChatView()) }
        select(min(max(store.selectedTab, 0), chats.count - 1), focus: false)
    }

    private func add(_ chat: AgentChatView, at index: Int? = nil) {
        chat.context = { [weak self] in
            guard let self else { return "" }
            return self.delegate?.agentPanelContext(self) ?? ""
        }
        chat.onChange = { [weak self, weak chat] in
            guard let self, let chat, self.chats.contains(chat) else { return }
            self.refresh()
            self.saveTabs()
        }
        chat.isHidden = true
        chat.translatesAutoresizingMaskIntoConstraints = false
        chatArea.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.topAnchor.constraint(equalTo: chatArea.topAnchor),
            chat.bottomAnchor.constraint(equalTo: chatArea.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: chatArea.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: chatArea.trailingAnchor),
        ])
        chats.insert(chat, at: index ?? chats.count)
    }

    /// Shows the tab at `index`, with the tab bar moved into it.
    private func select(_ index: Int, focus: Bool) {
        activeIndex = index
        for (i, chat) in chats.enumerated() { chat.isHidden = i != index }
        let chat = active
        if tabBar.superview !== chat.tabBarHost {
            tabBar.removeFromSuperview()
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            chat.tabBarHost.addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: chat.tabBarHost.topAnchor),
                tabBar.bottomAnchor.constraint(equalTo: chat.tabBarHost.bottomAnchor),
                tabBar.leadingAnchor.constraint(equalTo: chat.tabBarHost.leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: chat.tabBarHost.trailingAnchor),
            ])
        }
        refresh()
        saveTabs()
        if focus { window?.makeFirstResponder(chat.input) }
    }

    private func newTab() {
        guard chats.count < Settings.agentTabs else { return NSSound.beep() }
        add(AgentChatView())
        select(chats.count - 1, focus: true)
    }

    /// Starts over in the selected tab. The chat it had stays in history.
    private func newChat() {
        if active.isEmpty {
            window?.makeFirstResponder(input)
        } else {
            replace(activeIndex, with: AgentChatView())
        }
    }

    private func replace(_ index: Int, with chat: AgentChatView) {
        let old = chats.remove(at: index)
        old.shutDown()
        old.removeFromSuperview()
        add(chat, at: index)
        select(index, focus: true)
    }

    /// Closing the last tab leaves a new chat.
    private func closeTab(_ index: Int) {
        guard chats.indices.contains(index) else { return }
        if chats.count == 1 { return newChat() }
        let chat = chats.remove(at: index)
        chat.shutDown()
        chat.removeFromSuperview()
        let selected = index < activeIndex ? activeIndex - 1 : min(activeIndex, chats.count - 1)
        select(selected, focus: hasKeyboardFocus || index == activeIndex)
    }

    private func saveTabs() {
        AgentHistoryStore.shared.setOpenTabs(chats.map { $0.isEmpty ? "" : $0.id }, selected: activeIndex)
    }

    /// The header and tab bar show the selected chat.
    private func refresh() {
        let chat = active
        isBusy = chats.contains { $0.isBusy }
        agentPicker.selectItem(at: AgentKind.allCases.firstIndex(of: chat.kind) ?? 0)
        status.show(chat.statusText, busy: chat.statusBusy)
        tabBar.update(
            tabs: chats.map { (title: $0.title, busy: $0.isBusy) },
            selected: activeIndex,
            canAddTab: chats.count < Settings.agentTabs,
            tools: chat.tools
        )
    }

    // MARK: Tools

    /// The selected chat's built-in tools, each a checkmark item. Codex can
    /// always read and run read-only commands, so only writing changes for it.
    /// Locked while a turn runs, since a change restarts the agent.
    private func showTools(from button: NSView) {
        let chat = active
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Also allow in this chat"))
        for tool in AgentTool.allCases {
            let item = NSMenuItem(title: tool.displayName, action: #selector(toggleTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            let alwaysOn = chat.kind == .codex && tool != .write
            item.state = alwaysOn || chat.tools.contains(tool) ? .on : .off
            item.isEnabled = !alwaysOn && !chat.isBusy
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(
            title: chat.isBusy ? "Stop the agent to change tools." : "They run without asking. Settings sets them for new chats.",
            action: nil, keyEquivalent: ""
        )
        note.isEnabled = false
        menu.addItem(note)
        // Just below the button. The menu moves up if the screen runs out.
        let below = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: button)
    }

    @objc private func toggleTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AgentTool(rawValue: raw) else { return }
        let chat = active
        var tools = Set(chat.tools)
        if tools.contains(tool) { tools.remove(tool) } else { tools.insert(tool) }
        chat.setTools(AgentTool.allCases.filter(tools.contains))
    }

    @objc private func tabLimitChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: History

    private func showHistory(from button: NSView) {
        if let historyPopover, historyPopover.isShown { return historyPopover.close() }
        let controller = AgentHistoryController(items: historyItems(), current: active.id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onOpen = { [weak self, weak popover] id in
            popover?.close()
            self?.open(id)
        }
        controller.onDelete = { [weak self, weak controller] id in
            guard let self else { return }
            self.delete(id)
            controller?.reload(self.historyItems())
        }
        historyPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func historyItems() -> [AgentHistoryController.Item] {
        AgentHistoryStore.shared.conversations.map { conversation in
            .init(conversation: conversation, tab: chats.firstIndex { $0.id == conversation.id })
        }
    }

    /// Switches to the chat if a tab has it, or opens it in the selected tab.
    func open(_ id: String) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            return select(index, focus: true)
        }
        guard let conversation = AgentHistoryStore.shared.conversation(id) else { return }
        let chat = AgentChatView(conversation: conversation)
        replace(activeIndex, with: chat)
        chat.scrollToBottom()
    }

    /// A tab showing the chat gets a new one instead.
    private func delete(_ id: String) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let old = chats.remove(at: index)
            old.shutDown()
            old.removeFromSuperview()
            add(AgentChatView(), at: index)
            select(activeIndex, focus: false)
        }
        AgentHistoryStore.shared.delete(id)
    }

    // MARK: Agent

    /// Picking another agent starts a new chat with it, unless the selected
    /// tab has no messages yet.
    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = AgentKind(rawValue: raw),
            kind != active.kind || kind != AgentKind.current
        else { return }
        let startOver = !active.isEmpty && kind != active.kind
        AgentKind.current = kind
        if startOver { newChat() } else { refresh() }
    }

    /// Settings changed the agent for new chats, which an empty tab shows.
    @objc private func currentAgentChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { active.stopForTesting() }

    func pasteAndSendForTesting(_ text: String) { active.pasteAndSendForTesting(text) }

    /// One of the tab bar's buttons, by name, for `ui.agentAction`.
    func performForTesting(_ action: String) {
        switch action {
        case "newChat": newChat()
        case "newTab": newTab()
        case "closeTab": closeTab(activeIndex)
        case "history": tabBar.historyForTesting()
        case "tools": tabBar.toolsForTesting()
        case "focus": window?.makeFirstResponder(input)
        default:
            if action.hasPrefix("tab"), let index = Int(action.dropFirst(3)), chats.indices.contains(index - 1) {
                select(index - 1, focus: true)
            }
        }
    }

    /// Puts `text` in the selected chat's message field, as if typed.
    func setTextForTesting(_ text: String) {
        window?.makeFirstResponder(input)
        active.setTextForTesting(text)
    }
    #endif

    func send(_ text: String) {
        active.send(text)
    }

    // MARK: Scheduled runs

    func isChatBusy(_ id: String) -> Bool {
        chats.contains { $0.id == id && $0.isBusy }
    }

    /// Sends a scheduled prompt in a new chat, without selecting it or taking
    /// the keyboard. Returns the chat's id, or nil when no tab can take it.
    /// `completion` gets the chat's id and how its turn ended.
    func runScheduled(_ schedule: ScheduledPrompt, completion: @escaping (String, AgentRunOutcome) -> Void) -> String? {
        guard let index = tabForScheduledRun() else { return nil }
        let chat = AgentChatView(kind: schedule.kind, tools: schedule.tools)
        if index == chats.count {
            add(chat)
            refresh()
            saveTabs()
        } else {
            let hadFocus = hasKeyboardFocus
            let old = chats.remove(at: index)
            old.shutDown()
            old.removeFromSuperview()
            add(chat, at: index)
            // The selected tab is replaced only when nothing else can be, and
            // keeps the keyboard if it had it.
            select(activeIndex, focus: hadFocus && index == activeIndex)
        }
        let id = chat.id
        chat.runScheduled(schedule) { outcome in completion(id, outcome) }
        return id
    }

    /// Where a scheduled run goes, from least to most in the way: an empty
    /// tab you aren't looking at, a new tab while there is room, the
    /// longest unused idle tab you aren't looking at, then the selected tab.
    /// Never a tab whose agent is working or that has a message being written.
    private func tabForScheduledRun() -> Int? {
        let idle = chats.indices.filter { !chats[$0].isBusy && !chats[$0].hasDraft }
        if let empty = idle.first(where: { chats[$0].isEmpty && $0 != activeIndex }) { return empty }
        if chats.count < Settings.agentTabs { return chats.count }
        let others = idle.filter { $0 != activeIndex }
        if let oldest = others.min(by: { chats[$0].updated < chats[$1].updated }) { return oldest }
        return idle.contains(activeIndex) ? activeIndex : nil
    }
}


// MARK: Header

/// Where the agent is at: a dot, pulsing while it works, and a short label.
private final class StatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Theme.busyDot / 2
        label.font = .systemFont(ofSize: Theme.FontSize.caption)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Theme.busyDot),
            dot.heightAnchor.constraint(equalToConstant: Theme.busyDot),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The dot's color is the only other sign of the state, so VoiceOver
        // reads the pill as one element whose label says it in words.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool) {
        label.stringValue = text
        isHidden = text.isEmpty
        toolTip = text
        setAccessibilityLabel("Agent status: \(text)")
        guard busy != self.busy else { return }
        self.busy = busy
        needsDisplay = true
        dot.layer?.removeAnimation(forKey: "pulse")
        if busy, !Theme.reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dot.layer?.backgroundColor = (busy ? Theme.accentColor : NSColor.systemGreen).layerColor
    }
}

// MARK: Empty state

/// What a new chat shows: what the agent can do, and a few things to ask.
final class AgentEmptyState: NSView {
    var onSuggestion: ((String) -> Void)?
    var kind: AgentKind? {
        didSet {
            guard let kind, kind != oldValue else { return }
            title.stringValue = "Ask \(kind.displayName)"
            badge.logo = kind.logo(size: 28)
        }
    }

    private let badge = SymbolBadge(symbol: "sparkles")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "It can read the page, click, type and open tabs for you. Type / for skills.")
    private static let subtitleWidth: CGFloat = 240

    private static let suggestions: [(symbol: String, text: String)] = [
        ("text.alignleft", "Summarize this page"),
        ("list.bullet", "List the key points"),
        ("magnifyingglass", "Find related pages"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: Theme.FontSize.title, weight: .semibold)
        title.alignment = .center

        subtitle.font = .systemFont(ofSize: Theme.FontSize.secondary)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = Self.subtitleWidth

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 6
        for (symbol, text) in Self.suggestions {
            let button = SuggestionButton(symbol: symbol, title: text) { [weak self] in self?.onSuggestion?(text) }
            buttons.addArrangedSubview(button)
            // One width for all, so the column reads as a list.
            button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }

        let stack = NSStackView(views: [badge, title, subtitle, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: badge)
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The subtitle wraps to the space there is, when the panel is narrower
    /// than its usual width. Set before the stack lays out, so it lays out once.
    override func layout() {
        let width = min(Self.subtitleWidth, bounds.width)
        if width > 0, subtitle.preferredMaxLayoutWidth != width { subtitle.preferredMaxLayoutWidth = width }
        super.layout()
    }
}

/// An SF Symbol on a soft accent-colored circle, or a logo on a plain one.
private final class SymbolBadge: NSView {
    /// Shown instead of the symbol, in its own colors.
    var logo: NSImage? {
        didSet {
            image.image = logo ?? symbol
            image.contentTintColor = logo == nil ? Theme.accentColor : nil
            needsDisplay = true
        }
    }

    private let symbol: NSImage
    private let image: NSImageView

    init(symbol: String) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))!
        image = NSImageView(image: self.symbol)
        super.init(frame: .zero)
        wantsLayer = true
        image.contentTintColor = Theme.accentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 48),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 24
        let color = logo == nil ? Theme.accent(Theme.Accent.soft) : Theme.fill(0.06)
        layer?.backgroundColor = color.layerColor
    }
}

/// A rounded, lightly filled button with an icon and a prompt, which
/// highlights on hover.
private final class SuggestionButton: NSView {
    private let action: () -> Void
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.plate
        layer?.cornerCurve = .continuous
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: Composer

/// The message field: a rounded box whose text grows with what is typed, up
/// to a few lines, with the attach button and the send/stop button in its
/// bottom corners. Attached images show above the text. Images pasted or
/// dropped on it go to `onImages`.
final class Composer: NSView {
    let textView = PlaceholderTextView()
    let sendButton = NSButton()
    let attachButton = Theme.iconButton("paperclip", label: "Attach Images")
    var onImages: (([NSImage]) -> Void)?
    var onOpenImage: ((Int) -> Void)?
    private let undo = UndoManager()
    private let scrollView = NSScrollView()
    private let thumbnails = ThumbnailGrid(side: 48, alignment: .leading)
    private var textHeight: NSLayoutConstraint!
    private var textBelowTop: NSLayoutConstraint!
    private var textBelowThumbnails: NSLayoutConstraint!
    private var isDropTarget = false {
        didSet { needsDisplay = true }
    }

    var attachments: [AgentAttachment] = [] {
        didSet {
            thumbnails.images = attachments.map(\.image)
            thumbnails.isHidden = attachments.isEmpty
            textBelowTop.isActive = attachments.isEmpty
            textBelowThumbnails.isActive = !attachments.isEmpty
            updateSendButton()
        }
    }

    private static let font = NSFont.systemFont(ofSize: Theme.FontSize.body)
    private static let maxLines: CGFloat = 8
    private static let sendImage = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
        .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
    private static let stopImage = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")?
        .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            // Typing undo steps refer to the old text.
            undo.removeAllActions()
            textChanged()
        }
    }

    override var undoManager: UndoManager? { undo }

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue }
    }

    /// Drawn instead of `placeholder` when that doesn't fit the field.
    var shortPlaceholder: String {
        get { textView.shortPlaceholder }
        set { textView.shortPlaceholder = newValue }
    }

    var isBusy = false {
        didSet { updateSendButton() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }
        textView.onPasteboardImages = { [weak self] pasteboard in self?.takeImages(from: pasteboard) ?? false }
        textView.imageDropTarget = self
        // The placeholder is drawn by hand, so VoiceOver gets it, and a
        // name for the field, from here.
        textView.setAccessibilityLabel("Message")
        registerForDraggedTypes(AgentAttachment.pasteboardTypes)

        thumbnails.isHidden = true
        thumbnails.onOpen = { [weak self] index in self?.onOpenImage?(index) }
        thumbnails.onRemove = { [weak self] index in
            guard let self else { return }
            let removed = self.attachments.remove(at: index)
            try? FileManager.default.removeItem(at: removed.url)
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        sendButton.isBordered = false
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.imagePosition = .imageOnly
        updateSendButton()

        for view in [thumbnails, scrollView, attachButton, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        textBelowTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        textBelowThumbnails = scrollView.topAnchor.constraint(equalTo: thumbnails.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
            thumbnails.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnails.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textBelowTop,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            scrollView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textHeight,
            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            attachButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: Theme.ButtonSize.bar),
            sendButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.bar),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func textChanged() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(Self.lineHeight, used), Self.lineHeight * Self.maxLines).rounded(.up)
        if textHeight.constant != height { textHeight.constant = height }
        updateSendButton()
        textView.needsDisplay = true
    }

    private func updateSendButton() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        sendButton.image = isBusy ? Self.stopImage : Self.sendImage
        sendButton.toolTip = isBusy ? "Stop (⎋)" : "Send (↩)"
        // A disabled button fades its image itself, so an empty field's
        // arrow starts from secondary rather than fading twice.
        sendButton.contentTintColor = isBusy ? .labelColor : empty ? .secondaryLabelColor : Theme.accentColor
        sendButton.isEnabled = isBusy || !empty
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let focused = window?.firstResponder === textView
        // The same corners as the skill picker that opens above it.
        layer?.cornerRadius = Theme.Radius.plate
        layer?.cornerCurve = .continuous
        // See-through over the panel's material, unless Reduce Transparency is on.
        let background: CGFloat = Theme.reduceTransparency ? 1 : 0.7
        layer?.backgroundColor = NSColor.controlBackgroundColor.dynamic(alpha: background).layerColor
        let border: NSColor = isDropTarget ? Theme.accentColor
            : focused ? Theme.accent(Theme.Accent.outline) : Theme.hairline
        withEasing(Theme.Duration.quick) {
            layer?.borderWidth = isDropTarget ? 2 : Theme.hairlineWidth
            layer?.borderColor = border.layerColor
        }
    }

    /// Clicks anywhere in the box go to the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    /// Hands the pasteboard's images to `onImages`, and returns false if it
    /// has none, so it is pasted as text.
    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        guard AgentAttachment.canRead(pasteboard) else { return false }
        onImages?(AgentAttachment.images(on: pasteboard))
        return true
    }

    // MARK: Dropping images

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget = AgentAttachment.canRead(sender.draggingPasteboard)
        return isDropTarget ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return takeImages(from: sender.draggingPasteboard)
    }
}

/// The images Quick Look shows for the panel.
final class QuickLookItems: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    var index = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

/// A text view that shows a grey hint while empty and reports focus changes.
/// Images pasted into it go to `onPasteboardImages`, and images dragged onto
/// it go to `imageDropTarget`.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
            setAccessibilityPlaceholderValue(placeholder)
        }
    }
    /// Drawn when `placeholder` would truncate. VoiceOver still reads the
    /// full one.
    var shortPlaceholder = "" {
        didSet { needsDisplay = true }
    }
    var onFocusChange: (() -> Void)?
    /// Takes the pasteboard's images, returning false if it has none.
    var onPasteboardImages: ((NSPasteboard) -> Bool)?
    weak var imageDropTarget: NSView?

    override func paste(_ sender: Any?) {
        if onPasteboardImages?(.general) != true { super.paste(sender) }
    }

    /// Paste is on for an image, which plain text can't take.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteboardImages != nil, AgentAttachment.canRead(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + AgentAttachment.pasteboardTypes
    }

    private func dropsImages(_ sender: (any NSDraggingInfo)?) -> Bool {
        guard let sender, imageDropTarget != nil else { return false }
        return AgentAttachment.canRead(sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingEntered(sender) : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingUpdated(sender) : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if dropsImages(sender) { imageDropTarget!.draggingExited(sender) } else { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) ? imageDropTarget!.performDragOperation(sender) : super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: Theme.FontSize.body),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        let available = bounds.width - origin.x - textContainerOrigin.x - padding
        var text = NSAttributedString(string: placeholder, attributes: attributes)
        // A shorter hint whole reads better than the long one cut off.
        if !shortPlaceholder.isEmpty, ceil(text.size().width) > available {
            text = NSAttributedString(string: shortPlaceholder, attributes: attributes)
        }
        text.draw(with: NSRect(origin: origin, size: NSSize(width: available, height: bounds.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The hint that fits depends on the width, so it is drawn again on a resize.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, string.isEmpty, !placeholder.isEmpty { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }
}
