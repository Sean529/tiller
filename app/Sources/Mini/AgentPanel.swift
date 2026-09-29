import AppKit

@MainActor
protocol AgentPanelDelegate: AnyObject {
    /// The selected tab, described for the agent at the start of each message.
    func agentPanelContext(_ panel: AgentPanelView) -> String
}

/// The side panel: pick an agent, chat with it, and watch its browser tool calls.
final class AgentPanelView: NSView, NSTextViewDelegate {
    weak var delegate: AgentPanelDelegate?

    /// The message being written.
    var input: NSView { composer.textView }

    private let background = NSVisualEffectView()
    private let agentPicker = NSPopUpButton()
    private let status = StatusPill()
    private let newChatButton = NSButton()
    private let separator = NSBox()
    private let transcript = TranscriptView()
    private let scrollView = NSScrollView()
    private let emptyState = AgentEmptyState()
    private let composer = Composer()

    private var session: AgentSession?
    /// The text block Claude Code is streaming into, until the complete block arrives.
    private var liveText: NSTextField?
    private var liveTextBuffer = ""
    /// Streamed text is drawn at most this often, so a fast stream doesn't
    /// re-render the whole block for every few characters.
    private var liveTextRenderPending = false
    private static let liveTextInterval = 0.05
    private var toolRows: [String: ToolRowView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        showIdle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Ends the agent process. Called when the window closes.
    func shutDown() {
        session?.stop()
        session = nil
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
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        for kind in AgentKind.allCases {
            agentPicker.addItem(withTitle: kind.displayName)
            agentPicker.lastItem?.representedObject = kind.rawValue
        }
        agentPicker.selectItem(at: AgentKind.allCases.firstIndex(of: .current) ?? 0)
        agentPicker.isBordered = false
        agentPicker.font = .systemFont(ofSize: 13, weight: .semibold)
        agentPicker.toolTip = "Agent for new chats"
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged(_:))

        newChatButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        newChatButton.toolTip = "New Chat"
        newChatButton.bezelStyle = .accessoryBarAction
        newChatButton.isBordered = false
        newChatButton.contentTintColor = .secondaryLabelColor
        newChatButton.target = self
        newChatButton.action = #selector(newChat(_:))

        separator.boxType = .separator
        separator.alphaValue = 0

        scrollView.documentView = transcript
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Shows the header rule only once the transcript scrolls under it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(transcriptScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        emptyState.onSuggestion = { [weak self] text in self?.send(text) }

        composer.textView.delegate = self
        composer.sendButton.target = self
        composer.sendButton.action = #selector(sendOrStop(_:))

        for view in [background, agentPicker, status, newChatButton, scrollView, separator, emptyState, composer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            agentPicker.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            agentPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: agentPicker.trailingAnchor, constant: 4),
            status.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: newChatButton.leadingAnchor, constant: -6),
            newChatButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newChatButton.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),

            separator.topAnchor.constraint(equalTo: agentPicker.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),

            transcript.topAnchor.constraint(equalTo: clip.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            transcript.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),

            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @objc private func transcriptScrolled(_ notification: Notification) {
        let scrolled = scrollView.contentView.bounds.minY > 1
        if (separator.alphaValue > 0) != scrolled { separator.alphaValue = scrolled ? 1 : 0 }
    }

    // MARK: Actions

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = AgentKind(rawValue: raw),
            kind != AgentKind.current
        else { return }
        AgentKind.current = kind
        startNewChat()
    }

    /// Settings changed the default agent. A running chat keeps its agent; the
    /// next new chat uses the one now shown in the picker.
    @objc private func currentAgentChanged(_ notification: Notification) {
        agentPicker.selectItem(at: AgentKind.allCases.firstIndex(of: .current) ?? 0)
        if session == nil { showIdle() }
    }

    @objc private func newChat(_ sender: Any?) {
        startNewChat()
    }

    private func startNewChat() {
        shutDown()
        transcript.clear()
        liveText = nil
        toolRows.removeAll()
        showIdle()
        window?.makeFirstResponder(input)
    }

    #if DEBUG
    func stopForTesting() { sendOrStop(nil) }
    #endif

    @objc private func sendOrStop(_ sender: Any?) {
        if session?.isBusy == true {
            session?.interrupt()
            status.show("Stopping…", busy: true)
        } else {
            submit()
        }
    }

    /// Enter sends. Option+Enter or Shift+Enter adds a line. Escape stops a
    /// running turn.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) || flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                submit()
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard session?.isBusy == true else { return false }
            sendOrStop(nil)
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        composer.textChanged()
    }

    /// The composer keeps its own undo, which a sent message clears.
    func undoManager(for view: NSTextView) -> UndoManager? {
        composer.undoManager
    }

    private func submit() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session?.isBusy != true else { return }
        composer.text = ""
        send(text)
    }

    func send(_ text: String) {
        let session = self.session ?? makeSession()
        emptyState.isHidden = true
        transcript.add(UserMessageView(text: text))
        do {
            try session.send(text, context: delegate?.agentPanelContext(self) ?? "")
            if session.isRunning { status.show("Working…", busy: true) }
            setBusy(true)
        } catch {
            addError((error as? ControlError)?.message ?? error.localizedDescription)
            shutDown()
            showIdle()
        }
        scrollToBottom()
    }

    private func makeSession() -> AgentSession {
        let session = AgentSession(kind: .current)
        session.onEvent = { [weak self] event in self?.handle(event) }
        self.session = session
        status.show("Starting…", busy: true)
        return session
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        let follow = transcript.isNearBottom(of: scrollView)
        switch event {
        case .ready(let model):
            status.show(model.map { "Working · \($0)" } ?? "Working…", busy: true)
        case .textStarted:
            liveTextBuffer = ""
            let label = AgentMarkdown.label("")
            liveText = label
            transcript.add(label)
        case .textDelta(let delta):
            liveTextBuffer += delta
            scheduleLiveTextRender()
            return
        case .text(let text):
            if let liveText {
                liveText.attributedStringValue = AgentMarkdown.render(text)
                self.liveText = nil
            } else {
                transcript.add(AgentMarkdown.label(text))
            }
        case .toolUse(let id, let name, let input):
            let row = ToolRowView(name: name, input: input)
            toolRows[id] = row
            transcript.add(row)
        case .toolResult(let id, let isError, let summary):
            toolRows.removeValue(forKey: id)?.finish(isError: isError, summary: summary)
        case .retrying:
            status.show("Retrying…", busy: true)
        case .error(let message):
            addError(message)
        case .turnFinished(let error, let stopped):
            if let error { addError(error) }
            if stopped { addNote("Stopped") }
            liveText = nil
            showIdle()
        case .exited(let message):
            if let message { addError(message + "\nThe next message starts a new conversation.") }
            session = nil
            liveText = nil
            toolRows.removeAll()
            showIdle()
        }
        if follow { scrollToBottom() }
    }

    private func scheduleLiveTextRender() {
        guard !liveTextRenderPending else { return }
        liveTextRenderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveTextInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveTextRenderPending = false
                guard let liveText = self.liveText else { return }
                let follow = self.transcript.isNearBottom(of: self.scrollView)
                liveText.attributedStringValue = AgentMarkdown.render(self.liveTextBuffer)
                if follow { self.scrollToBottom() }
            }
        }
    }

    private func showIdle() {
        setBusy(false)
        let kind = session?.kind ?? .current
        if session == nil {
            status.show("", busy: false)
        } else {
            status.show("Ready", busy: false)
        }
        composer.placeholder = "Ask \(kind.displayName) about this page…"
        emptyState.agentName = kind.displayName
        emptyState.isHidden = !transcript.isEmpty
    }

    private func setBusy(_ busy: Bool) {
        composer.isBusy = busy
    }

    private func addNote(_ message: String) {
        transcript.add(NoteView(text: message))
    }

    private func addError(_ message: String) {
        transcript.add(ErrorMessageView(text: message))
    }

    /// Keeps the newest message in view. Agent events call this only when the
    /// user hasn't scrolled up to read something.
    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = max(0, transcript.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
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
        dot.layer?.cornerRadius = 3
        label.font = .systemFont(ofSize: 11)
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
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool) {
        label.stringValue = text
        isHidden = text.isEmpty
        toolTip = text
        guard busy != self.busy else { return }
        self.busy = busy
        needsDisplay = true
        dot.layer?.removeAnimation(forKey: "pulse")
        if busy {
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
        dot.layer?.backgroundColor = (busy ? NSColor.controlAccentColor : NSColor.systemGreen).cgColor
    }
}

// MARK: Empty state

/// What a new chat shows: what the agent can do, and a few things to ask.
private final class AgentEmptyState: NSView {
    var onSuggestion: ((String) -> Void)?
    var agentName = "" {
        didSet { title.stringValue = "Ask \(agentName)" }
    }

    private let title = NSTextField(labelWithString: "")

    private static let suggestions: [(symbol: String, text: String)] = [
        ("text.alignleft", "Summarize this page"),
        ("list.bullet", "List the key points"),
        ("magnifyingglass", "Find related pages"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let badge = SymbolBadge(symbol: "sparkles")

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: "It can read the page, click, type and open tabs for you.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 240

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
}

/// An SF Symbol on a soft accent-colored circle.
private final class SymbolBadge: NSView {
    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))!)
        image.contentTintColor = .controlAccentColor
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
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
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
        label.font = .systemFont(ofSize: 12)
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
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        let alpha = isPressed ? 0.14 : isHovered ? 0.09 : 0.05
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: Composer

/// The message field: a rounded box whose text grows with what is typed, up
/// to a few lines, with the send/stop button in its corner.
private final class Composer: NSView {
    let textView = PlaceholderTextView()
    let sendButton = NSButton()
    private let undo = UndoManager()
    private let scrollView = NSScrollView()
    private var textHeight: NSLayoutConstraint!

    private static let font = NSFont.systemFont(ofSize: 13)
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

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        sendButton.isBordered = false
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.imagePosition = .imageOnly
        updateSendButton()

        for view in [scrollView, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textHeight,
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: 26),
            sendButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

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
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.image = isBusy ? Self.stopImage : Self.sendImage
        sendButton.toolTip = isBusy ? "Stop (Esc)" : "Send (Return)"
        sendButton.contentTintColor = isBusy ? .labelColor : empty ? .tertiaryLabelColor : .controlAccentColor
        sendButton.isEnabled = isBusy || !empty
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let focused = window?.firstResponder === textView
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (focused ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor).cgColor
    }

    /// Clicks anywhere in the box go to the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}

/// A text view that shows a grey hint while empty and reports focus changes.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onFocusChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(with: NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x, height: bounds.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
