import AppKit
import Quartz

/// One chat in the agent panel: its transcript, its message field and the
/// agent process behind it. Each tab of the panel holds one. A chat is saved
/// to history with its first message, and one opened from history continues
/// the CLI's saved session on the next message.
final class AgentChatView: NSView, NSTextViewDelegate {
    /// The selected tab, described for the agent at the start of each message.
    var context: (() -> String)?
    /// Called when the title, status or agent changes, or a turn starts or ends.
    var onChange: (() -> Void)?

    let id: String
    /// Nil until the first message.
    private(set) var conversation: AgentConversation?
    private(set) var statusText = ""
    private(set) var statusBusy = false

    /// The message being written.
    var input: NSView { composer.textView }
    var isEmpty: Bool { conversation == nil }
    var isBusy: Bool { session?.isBusy == true }
    /// A new chat uses the agent picked for new chats until its first message.
    var kind: AgentKind { conversation?.kind ?? .current }
    var title: String { conversation?.title ?? "New Chat" }
    /// The built-in tools this chat allows. A new chat starts with Settings'.
    private(set) var tools: [AgentTool]

    /// Where the panel puts its tab bar, between the transcript and the field.
    let tabBarHost = NSView()

    private let separator = NSBox()
    private let transcript = TranscriptView()
    private let scrollView = NSScrollView()
    private let emptyState = AgentEmptyState()
    private let composer = Composer()

    private var session: AgentSession?
    /// Set while a session resumes a saved conversation and hasn't started yet.
    private var resuming = false
    private var records: [AgentRecord] = []
    /// The text block Claude Code is streaming into, until the complete block arrives.
    private var liveText: MarkdownMessageView?
    private var liveTextBuffer = ""
    /// Streamed text is drawn at most this often, so a fast stream doesn't
    /// re-render the whole block for every few characters.
    private var liveTextRenderPending = false
    private static let liveTextInterval = 0.05
    /// Running tool calls: their rows and where they are in `records`.
    private var toolRows: [String: (row: ToolRowView, record: Int)] = [:]
    private let quickLook = QuickLookItems()

    private var folder: URL { AgentHistoryStore.shared.folder(for: id) }
    /// A saved chat opens at its newest message once it has a size.
    private var pendingScrollToBottom = false

    /// A new chat, or a saved one with its transcript.
    init(conversation: AgentConversation? = nil) {
        id = conversation?.id ?? UUID().uuidString
        self.conversation = conversation
        tools = conversation?.tools ?? Settings.agentTools
        super.init(frame: .zero)
        build()
        if conversation != nil {
            records = AgentHistoryStore.shared.records(for: id)
            records.forEach(show)
            transcript.closeToolGroup()
            pendingScrollToBottom = !records.isEmpty
        }
        showIdle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Ends the agent process, keeping what it said so far. A chat that was
    /// never sent loses its images. Called when the tab closes or the window does.
    func shutDown() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().dataSource === quickLook {
            QLPreviewPanel.shared().orderOut(nil)
        }
        if isBusy {
            keepLiveText()
            addNote("Stopped")
        }
        finishToolRows()
        transcript.closeToolGroup()
        endSession()
        for attachment in composer.attachments { try? FileManager.default.removeItem(at: attachment.url) }
        composer.attachments = []
        AgentHistoryStore.shared.discardUnsaved(id)
    }

    private func endSession() {
        session?.stop()
        session = nil
        resuming = false
    }

    // MARK: Layout

    private func build() {
        separator.boxType = .separator
        separator.alphaValue = 0

        scrollView.documentView = transcript
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Shows the rule at the top only once the transcript scrolls under it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(transcriptScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        emptyState.onSuggestion = { [weak self] text in self?.send(text) }

        composer.textView.delegate = self
        composer.sendButton.target = self
        composer.sendButton.action = #selector(sendOrStop(_:))
        composer.attachButton.target = self
        composer.attachButton.action = #selector(chooseImages(_:))
        composer.onImages = { [weak self] images in self?.attach(images) }
        composer.onOpenImage = { [weak self] index in
            guard let self else { return }
            self.preview(self.composer.attachments.map(\.url), at: index)
        }

        for view in [scrollView, separator, emptyState, tabBarHost, composer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tabBarHost.topAnchor, constant: -4),

            transcript.topAnchor.constraint(equalTo: clip.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            transcript.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),

            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            tabBarHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBarHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabBarHost.heightAnchor.constraint(equalToConstant: AgentTabBar.height),
            tabBarHost.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    override func layout() {
        super.layout()
        guard pendingScrollToBottom, bounds.height > 0, !isHidden else { return }
        pendingScrollToBottom = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scrollToBottom() } }
    }

    @objc private func transcriptScrolled(_ notification: Notification) {
        let scrolled = scrollView.contentView.bounds.minY > 1
        if (separator.alphaValue > 0) != scrolled { separator.alphaValue = scrolled ? 1 : 0 }
    }

    /// Settings or the picker changed the agent for new chats.
    @objc private func currentAgentChanged(_ notification: Notification) {
        if session == nil { showIdle() }
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { sendOrStop(nil) }

    /// Pastes the clipboard into the composer twice, as Cmd+V would, then
    /// sends `text` with it after a few seconds.
    func pasteAndSendForTesting(_ text: String) {
        composer.textView.paste(nil)
        composer.textView.paste(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                self?.composer.text = text
                self?.submit()
            }
        }
    }
    #endif

    @objc private func sendOrStop(_ sender: Any?) {
        if isBusy {
            session?.interrupt()
            setStatus("Stopping…", busy: true)
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
            guard isBusy else { return false }
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
        let images = composer.attachments
        guard !text.isEmpty || !images.isEmpty, !isBusy else { return }
        composer.text = ""
        composer.attachments = []
        send(text, images: images)
    }

    func send(_ text: String, images: [AgentAttachment] = []) {
        var conversation = conversation ?? AgentConversation(
            id: id, kind: .current, title: AgentConversation.title(from: text), created: Date(), updated: Date()
        )
        conversation.tools = tools
        conversation.updated = Date()
        save(conversation)
        let session = self.session ?? makeSession()
        emptyState.isHidden = true
        records.append(.user(text: text, images: images.map(\.url.lastPathComponent)))
        saveRecords()
        transcript.add(UserMessageView(text: text, images: images.map(\.image)) { [weak self] index in
            self?.preview(images.map(\.url), at: index)
        })
        do {
            try session.send(text, images: images, context: context?() ?? "")
            if session.isRunning { setStatus("Working…", busy: true) }
            setBusy(true)
        } catch {
            addError((error as? ControlError)?.message ?? error.localizedDescription)
            endSession()
            showIdle()
        }
        scrollToBottom()
    }

    private func save(_ conversation: AgentConversation) {
        let changed = self.conversation != conversation
        self.conversation = conversation
        AgentHistoryStore.shared.save(conversation)
        if changed { onChange?() }
    }

    private func saveRecords() {
        guard conversation != nil else { return }
        AgentHistoryStore.shared.setRecords(records, for: id)
    }

    /// Continues the saved session if there is one, in the folder it ran in.
    private func makeSession() -> AgentSession {
        let conversation = conversation!
        var directory: URL?
        if conversation.sessionID != nil, let path = conversation.directory {
            directory = URL(fileURLWithPath: path)
        }
        let session = AgentSession(kind: conversation.kind, tools: tools, resuming: conversation.sessionID, in: directory)
        session.onEvent = { [weak self] event in self?.handle(event) }
        self.session = session
        resuming = conversation.sessionID != nil
        setStatus("Starting…", busy: true)
        return session
    }

    // MARK: Tools

    /// Changes the built-in tools. The CLIs take them when they start, so a
    /// running agent is stopped and the next message resumes its session with
    /// the new ones. Not while a turn is running.
    func setTools(_ tools: [AgentTool]) {
        guard !isBusy, tools != self.tools else { return }
        self.tools = tools
        if var conversation {
            conversation.tools = tools
            save(conversation)
        }
        if session != nil {
            endSession()
            showIdle()
        }
        onChange?()
    }

    // MARK: Images

    /// Adds pasted, dropped or chosen images to the message, up to the limit.
    /// Beeps for any that don't fit or can't be read.
    private func attach(_ images: [NSImage]) {
        let room = max(0, AgentAttachment.maxCount - composer.attachments.count)
        let added = images.prefix(room).compactMap { AgentAttachment(image: $0, in: folder) }
        if added.count < images.count { NSSound.beep() }
        composer.attachments += added
    }

    @objc private func chooseImages(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to send to the agent."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK { self.attach(panel.urls.compactMap(NSImage.init(contentsOf:))) }
            window.makeFirstResponder(self.input)
        }
    }

    /// Shows the images in Quick Look, starting at `index`. The panel asks the
    /// responder chain for a controller, so the focus moves into this chat
    /// if it is elsewhere.
    private func preview(_ urls: [URL], at index: Int) {
        quickLook.urls = urls
        quickLook.index = index
        if !hasKeyboardFocus { window?.makeFirstResponder(input) }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLook
        panel.reloadData()
        panel.currentPreviewItemIndex = quickLook.index
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        let follow = transcript.isNearBottom(of: scrollView)
        switch event {
        case .ready(let model):
            setStatus(model.map { "Working · \($0)" } ?? "Working…", busy: true)
        case .sessionStarted(let sessionID):
            resuming = false
            guard var conversation else { break }
            conversation.sessionID = sessionID
            conversation.directory = session?.directory?.path
            save(conversation)
        case .renamed(let title):
            guard var conversation else { break }
            conversation.title = title
            save(conversation)
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
                liveText.text = text
                self.liveText = nil
            } else {
                transcript.add(AgentMarkdown.label(text))
            }
            records.append(.text(text))
            saveRecords()
        case .toolUse(let id, let name, let input):
            let detail = ToolRowView.detail(input)
            let row = ToolRowView(name: name, detail: detail)
            records.append(.tool(name: name, detail: detail, isError: nil, summary: ""))
            saveRecords()
            toolRows[id] = (row, records.count - 1)
            transcript.add(row)
        case .toolResult(let id, let isError, let summary):
            guard let (row, index) = toolRows.removeValue(forKey: id) else { break }
            row.finish(isError: isError, summary: summary)
            if case .tool(let name, let detail, _, _) = records[index] {
                records[index] = .tool(name: name, detail: detail, isError: isError, summary: summary)
                saveRecords()
            }
        case .retrying:
            setStatus("Retrying…", busy: true)
        case .error(let message):
            addError(message)
        case .turnFinished(let error, let stopped):
            keepLiveText()
            transcript.closeToolGroup()
            if let error { addError(error) }
            if stopped { addNote("Stopped") }
            showIdle()
            readTitle()
        case .exited(let message):
            keepLiveText()
            finishToolRows()
            transcript.closeToolGroup()
            if resuming {
                // The saved session couldn't be continued, so start over.
                conversation?.sessionID = nil
                if let conversation { save(conversation) }
                addError((message ?? "\(kind.displayName) couldn't continue this chat.")
                    + "\nThe next message starts a new conversation, without what was said before.")
            } else if let message {
                addError(message + "\nThe next message continues the conversation.")
            }
            session = nil
            resuming = false
            showIdle()
        }
        if follow { scrollToBottom() }
    }

    /// Keeps the text a turn was streaming when it ended without the complete block.
    private func keepLiveText() {
        if liveText != nil, !liveTextBuffer.isEmpty {
            records.append(.text(liveTextBuffer))
            saveRecords()
        }
        liveText = nil
    }

    /// Calls still running when the agent ended get a mark of their own.
    private func finishToolRows() {
        for (row, _) in toolRows.values { row.finish(isError: nil, summary: "") }
        toolRows.removeAll()
    }

    /// Claude Code and Qoder CLI may name the session in their own files.
    private func readTitle() {
        guard let conversation, let sessionID = conversation.sessionID, let directory = conversation.directory else { return }
        let kind = conversation.kind
        Task { [weak self] in
            let title = await Task.detached {
                AgentSessionTitle.read(kind: kind, sessionID: sessionID, directory: directory)
            }.value
            guard let self, let title, var conversation = self.conversation, conversation.title != title else { return }
            conversation.title = title
            self.save(conversation)
        }
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
                liveText.text = self.liveTextBuffer
                if follow { self.scrollToBottom() }
            }
        }
    }

    private func showIdle() {
        setBusy(false)
        setStatus(session == nil ? "" : "Ready", busy: false)
        composer.placeholder = "Ask \(kind.displayName) about this page…"
        emptyState.kind = kind
        emptyState.isHidden = !transcript.isEmpty
    }

    private func setBusy(_ busy: Bool) {
        guard composer.isBusy != busy else { return }
        composer.isBusy = busy
        onChange?()
    }

    private func setStatus(_ text: String, busy: Bool) {
        guard text != statusText || busy != statusBusy else { return }
        statusText = text
        statusBusy = busy
        onChange?()
    }

    private func addNote(_ message: String) {
        records.append(.note(message))
        saveRecords()
        transcript.add(NoteView(text: message))
    }

    private func addError(_ message: String) {
        records.append(.error(message))
        saveRecords()
        transcript.add(ErrorMessageView(text: message))
    }

    /// Draws a saved row.
    private func show(_ record: AgentRecord) {
        switch record {
        case .user(let text, let names):
            let loaded = names.map { folder.appendingPathComponent($0) }
                .compactMap { url in NSImage(contentsOf: url).map { (url, $0) } }
            transcript.add(UserMessageView(text: text, images: loaded.map(\.1)) { [weak self] index in
                self?.preview(loaded.map(\.0), at: index)
            })
        case .text(let text):
            transcript.add(AgentMarkdown.label(text))
        case .tool(let name, let detail, let isError, let summary):
            let row = ToolRowView(name: name, detail: detail)
            row.finish(isError: isError, summary: summary)
            transcript.add(row)
        case .note(let text):
            transcript.add(NoteView(text: text))
        case .error(let text):
            transcript.add(ErrorMessageView(text: text))
        }
    }

    /// Keeps the newest message in view. Agent events call this only when the
    /// user hasn't scrolled up to read something.
    func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = max(0, transcript.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
