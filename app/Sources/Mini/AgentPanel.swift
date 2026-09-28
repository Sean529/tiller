import AppKit

@MainActor
protocol AgentPanelDelegate: AnyObject {
    /// The selected tab, described for the agent at the start of each message.
    func agentPanelContext(_ panel: AgentPanelView) -> String
}

/// The side panel: pick an agent, chat with it, and watch its browser tool calls.
final class AgentPanelView: NSView {
    weak var delegate: AgentPanelDelegate?

    let input = NSTextField()
    private let agentPicker = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let newChatButton = NSButton()
    private let sendButton = NSButton()
    private let transcript = TranscriptView()
    private let scrollView = NSScrollView()

    private var session: AgentSession?
    /// The text block Claude Code is streaming into, until the complete block arrives.
    private var liveText: NSTextField?
    private var liveTextBuffer = ""
    private var toolRows: [String: ToolRow] = [:]

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
        for kind in AgentKind.allCases {
            agentPicker.addItem(withTitle: kind.displayName)
            agentPicker.lastItem?.representedObject = kind.rawValue
        }
        agentPicker.selectItem(at: AgentKind.allCases.firstIndex(of: .current) ?? 0)
        agentPicker.controlSize = .small
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged(_:))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        newChatButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")
        newChatButton.toolTip = "New Chat"
        newChatButton.bezelStyle = .accessoryBarAction
        newChatButton.isBordered = false
        newChatButton.target = self
        newChatButton.action = #selector(newChat(_:))

        scrollView.documentView = transcript
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        input.placeholderString = "Ask about this page…"
        input.font = .systemFont(ofSize: 13)
        input.usesSingleLineMode = false
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        input.maximumNumberOfLines = 6
        input.lineBreakMode = .byWordWrapping
        input.bezelStyle = .roundedBezel
        input.target = self
        input.action = #selector(submit(_:))

        sendButton.bezelStyle = .accessoryBarAction
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(sendOrStop(_:))

        let separator = NSBox()
        separator.boxType = .separator

        for view in [agentPicker, statusLabel, newChatButton, separator, scrollView, input, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            agentPicker.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            agentPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: agentPicker.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: newChatButton.leadingAnchor, constant: -6),
            newChatButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newChatButton.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),

            separator.topAnchor.constraint(equalTo: agentPicker.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),

            transcript.topAnchor.constraint(equalTo: clip.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            transcript.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),

            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            input.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: input.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 22),
        ])
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
            statusLabel.stringValue = "Stopping…"
        } else {
            submit(input)
        }
    }

    /// Enter sends. Option+Enter inserts a newline (the field editor's default).
    @objc private func submit(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session?.isBusy != true else { return }
        sender.stringValue = ""
        send(text)
    }

    func send(_ text: String) {

        let session = self.session ?? makeSession()
        transcript.add(Self.bubble(text))
        do {
            try session.send(text, context: delegate?.agentPanelContext(self) ?? "")
            statusLabel.stringValue = session.isRunning ? "Working…" : ""
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
        statusLabel.stringValue = "Starting \(session.kind.displayName)…"
        return session
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .ready(let model):
            statusLabel.stringValue = model.map { "Working… · \($0)" } ?? "Working…"
        case .textStarted:
            liveTextBuffer = ""
            let label = Self.textLabel("")
            liveText = label
            transcript.add(label)
        case .textDelta(let delta):
            liveTextBuffer += delta
            liveText?.attributedStringValue = Self.markdown(liveTextBuffer)
        case .text(let text):
            if let liveText {
                liveText.attributedStringValue = Self.markdown(text)
                self.liveText = nil
            } else {
                transcript.add(Self.textLabel(text))
            }
        case .toolUse(let id, let name, let input):
            let row = ToolRow(name: name, input: input)
            toolRows[id] = row
            transcript.add(row.label)
        case .toolResult(let id, let isError, let summary):
            toolRows.removeValue(forKey: id)?.finish(isError: isError, summary: summary)
        case .retrying:
            statusLabel.stringValue = "Retrying…"
        case .turnFinished(let error, let stopped):
            if let error { addError(error) }
            if stopped { addNote("Stopped.") }
            liveText = nil
            showIdle()
        case .exited(let message):
            if let message { addError(message + "\nThe next message starts a new conversation.") }
            session = nil
            liveText = nil
            toolRows.removeAll()
            showIdle()
        }
        scrollToBottom()
    }

    private func showIdle() {
        setBusy(false)
        let kind = session?.kind ?? .current
        statusLabel.stringValue = session == nil ? "" : "Ready"
        input.placeholderString = "Ask \(kind.displayName) about this page…"
    }

    private func setBusy(_ busy: Bool) {
        let name = busy ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.image = NSImage(systemSymbolName: name, accessibilityDescription: busy ? "Stop" : "Send")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        sendButton.toolTip = busy ? "Stop" : "Send"
        sendButton.contentTintColor = busy ? .secondaryLabelColor : .controlAccentColor
    }

    private func addNote(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        transcript.add(label)
    }

    private func addError(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        transcript.add(label)
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = max(0, transcript.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Rows

    static func textLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = markdown(text)
        label.isSelectable = true
        return label
    }

    /// Inline markdown (bold, code, links). Block syntax stays as typed.
    static func markdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: whole)
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
            } else if intent.contains(.stronglyEmphasized) {
                result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
            }
        }
        return result
    }

    static func bubble(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        return BubbleView(label: label)
    }
}

/// One tool call: "◦ navigate example.com", then ✓ or ✗ with the first line of the result.
@MainActor
final class ToolRow {
    let label = NSTextField(wrappingLabelWithString: "")
    private let title: String

    init(name: String, input: [String: Any]) {
        let tool = name.hasPrefix("mcp__mini__") ? String(name.dropFirst("mcp__mini__".count)) : name
        let detail = Self.detail(input)
        title = detail.isEmpty ? tool : "\(tool)  \(detail)"
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.stringValue = "◦ " + title
    }

    func finish(isError: Bool, summary: String) {
        if isError {
            label.stringValue = "✗ \(title)\n  \(summary)"
            label.textColor = .systemRed
        } else {
            label.stringValue = "✓ " + title
        }
    }

    /// The arguments worth showing: where it acts, and what it types or runs.
    private static func detail(_ input: [String: Any]) -> String {
        var parts: [String] = []
        if let url = input["url"] { parts.append("\(url)") }
        if let ref = input["ref"] { parts.append("ref \(ref)") } else if let selector = input["selector"] { parts.append("\(selector)") }
        if let text = input["text"] { parts.append("\"\(text)\"") }
        if let expression = input["expression"] { parts.append("\(expression)") }
        if parts.isEmpty, let tab = input["tab_id"] { parts.append("tab \(tab)") }
        let string = parts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        return string.count > 80 ? String(string.prefix(80)) + "…" : string
    }
}

/// A user message: text on a tinted rounded background.
final class BubbleView: NSView {
    init(label: NSTextField) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// The scrolling column of messages. Flipped so rows stack from the top.
final class TranscriptView: NSView {
    private let stack = NSStackView()
    private static let inset: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        needsLayout = true
    }

    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
    }

    /// Wrapping labels need a max width to report their height.
    override func layout() {
        let width = bounds.width - 2 * Self.inset
        for label in labels(in: stack) {
            let max = label.superview is BubbleView ? width - 20 : width
            if label.preferredMaxLayoutWidth != max { label.preferredMaxLayoutWidth = max }
        }
        super.layout()
    }

    private func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
    }
}
