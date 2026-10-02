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
    /// Fades the transcript out under the header and above the tab bar, so a
    /// line is never sliced at either edge.
    private let topFade = EdgeFadeView(edge: .top)
    private let bottomFade = EdgeFadeView(edge: .bottom)
    /// Room above the first message and below the last, inside the scroll
    /// view, so neither sits on the fades.
    private static let insets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
    private let emptyState = AgentEmptyState()
    private let composer = Composer()
    private let skillPicker = SkillPicker()
    /// The skills the running agent said it loaded. Until then, `/` offers
    /// what Tiller finds on disk.
    private var loadedSkills: [AgentSkill]?
    /// What `/` offers while the picker is open, read when it opens.
    private var pickerSkills: [AgentSkill]?

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
    /// Brings the newest message back into view after scrolling up.
    private let scrollDownButton = ScrollDownButton()

    private var folder: URL { AgentHistoryStore.shared.folder(for: id) }
    /// A saved chat opens at its newest message once it has a size.
    private var pendingScrollToBottom = false

    /// Where the saved transcript is: still in its file, on its way from
    /// disk, or drawn. A saved chat waits until it is first shown or written
    /// to, so a launch with several tabs of long chats doesn't build them all
    /// behind a hidden panel.
    private enum LoadState {
        case unloaded
        /// Numbered, so a read that was overtaken is dropped when it lands.
        case loading(Int)
        case loaded
    }
    private var loadState: LoadState
    private var loadCount = 0
    private var recordsLoaded: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    /// A new chat, or a saved one with its transcript.
    init(conversation: AgentConversation? = nil) {
        id = conversation?.id ?? UUID().uuidString
        self.conversation = conversation
        tools = conversation?.tools ?? Settings.agentTools
        loadState = conversation == nil ? .loaded : .unloaded
        super.init(frame: .zero)
        build()
        showIdle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )
    }

    /// Reads and draws the saved transcript, once. The file and the
    /// thumbnails of its images are read off the main thread, since a long
    /// chat with screenshots would hold the tab switch up. `now` reads them
    /// here instead, for a send that is about to add to them.
    func loadIfNeeded(now: Bool = false) {
        switch loadState {
        case .loaded: return
        case .loading where !now: return
        case .loading, .unloaded: break
        }
        let folder = folder
        // The newest records may still be on their way to disk.
        let unwritten = AgentHistoryStore.shared.unwrittenRecords(for: id)
        if now {
            let records = unwritten ?? AgentHistoryStore.readRecords(in: folder)
            finishLoading(records, thumbnails: Self.thumbnails(for: records, in: folder))
            return
        }
        loadCount += 1
        let count = loadCount
        loadState = .loading(count)
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = unwritten ?? AgentHistoryStore.readRecords(in: folder)
            let thumbnails = Self.thumbnails(for: records, in: folder)
            await MainActor.run {
                guard let self, case .loading(count) = self.loadState else { return }
                self.finishLoading(records, thumbnails: thumbnails)
            }
        }
    }

    /// Thumbnails for every image a transcript names, by file name. Read
    /// from the files, not the whole images: a saved chat can hold a dozen
    /// screenshots.
    nonisolated private static func thumbnails(for records: [AgentRecord], in folder: URL) -> Thumbnails {
        var images: [String: NSImage] = [:]
        for case .user(_, let names) in records {
            for name in names where images[name] == nil {
                images[name] = AgentAttachment.thumbnail(at: folder.appendingPathComponent(name), side: 128)
            }
        }
        return Thumbnails(images: images)
    }

    /// Images made on a background thread and only used on the main one
    /// once they are handed over.
    private struct Thumbnails: @unchecked Sendable {
        let images: [String: NSImage]
    }

    private func finishLoading(_ records: [AgentRecord], thumbnails: Thumbnails) {
        loadState = .loaded
        self.records = records
        for record in records { show(record, thumbnails: thumbnails) }
        transcript.closeToolGroup()
        pendingScrollToBottom = !records.isEmpty
        showIdle()
        if pendingScrollToBottom { needsLayout = true }
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
        transcript.hideThinking()
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
        loadedSkills = nil
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
        scrollView.contentInsets = Self.insets
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

        skillPicker.isHidden = true
        skillPicker.onPick = { [weak self] skill in self?.complete(skill) }

        scrollDownButton.target = self
        scrollDownButton.action = #selector(scrollDown(_:))

        for view in [scrollView, topFade, bottomFade, separator, emptyState, scrollDownButton, tabBarHost, composer, skillPicker] as [NSView] {
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
            // Less the insets, so a short transcript doesn't scroll.
            transcript.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor, constant: -(Self.insets.top + Self.insets.bottom)),

            topFade.topAnchor.constraint(equalTo: scrollView.topAnchor),
            topFade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            topFade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            topFade.heightAnchor.constraint(equalToConstant: EdgeFadeView.height),
            bottomFade.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bottomFade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: EdgeFadeView.height),

            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            scrollDownButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            scrollDownButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -10),

            tabBarHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBarHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabBarHost.heightAnchor.constraint(equalToConstant: AgentTabBar.height),
            tabBarHost.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            skillPicker.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            skillPicker.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            skillPicker.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
        ])
    }

    override func layout() {
        super.layout()
        guard bounds.height > 0, !isHiddenOrHasHiddenAncestor else { return }
        loadIfNeeded()
        guard pendingScrollToBottom else { return }
        pendingScrollToBottom = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scrollToBottom() } }
    }

    /// Shown for the first time, or the panel came back: draw the saved chat.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if !recordsLoaded { needsLayout = true }
    }

    @objc private func transcriptScrolled(_ notification: Notification) {
        // At the top the clip's origin sits at minus the top inset.
        let scrolled = scrollView.contentView.bounds.minY > 1 - Self.insets.top
        if (separator.alphaValue > 0) != scrolled { separator.alphaValue = scrolled ? 1 : 0 }
        updateScrollDownButton()
    }

    /// The button shows once the newest message is more than a screen's
    /// worth out of view.
    private func updateScrollDownButton() {
        let clip = scrollView.contentView.bounds
        let away = transcript.frame.height - (clip.maxY - Self.insets.bottom)
        scrollDownButton.setShown(away > max(80, clip.height * 0.5))
    }

    @objc private func scrollDown(_ sender: Any?) {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = bottomOffset
        if Theme.reduceMotion {
            clip.scroll(to: NSPoint(x: 0, y: y))
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.panel
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Settings or the picker changed the agent for new chats.
    @objc private func currentAgentChanged(_ notification: Notification) {
        if session == nil { showIdle() }
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { sendOrStop(nil) }

    /// Replaces the message field's text, as typing would, so the skill
    /// picker follows it.
    func setTextForTesting(_ text: String) {
        composer.text = text
        updatePicker()
    }

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
        if !skillPicker.isHidden {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                skillPicker.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                skillPicker.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                if let skill = skillPicker.selectedSkill { complete(skill) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hidePicker()
                return true
            default:
                break
            }
        }
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
        updatePicker()
    }

    // MARK: Skills

    /// What `/` can call in this chat.
    private var availableSkills: [AgentSkill] {
        loadedSkills ?? AgentSkillCatalog.skills(for: kind)
    }

    /// Open while the text is a `/` and the start of a name, with nothing after.
    private func updatePicker() {
        let text = composer.text
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return hidePicker() }
        let skills = pickerSkills ?? availableSkills
        pickerSkills = skills
        skillPicker.show(skills, matching: String(text.dropFirst()))
    }

    private func hidePicker() {
        skillPicker.isHidden = true
        pickerSkills = nil
    }

    /// Puts `/name ` in the field, keeping it undoable.
    private func complete(_ skill: AgentSkill) {
        let textView = composer.textView
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        let replacement = "/" + skill.name + " "
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        hidePicker()
        window?.makeFirstResponder(textView)
    }

    /// The skill a message starting with `/name` calls.
    private func skill(calledBy text: String) -> AgentSkill? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return availableSkills.first { $0.name == name }
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
        hidePicker()
        send(text, images: images)
    }

    func send(_ text: String, images: [AgentAttachment] = []) {
        loadIfNeeded(now: true)
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
        // Only the files are kept for Quick Look, not the images' bytes.
        let urls = images.map(\.url)
        transcript.add(UserMessageView(text: text, images: images.map(\.image)) { [weak self] index in
            self?.preview(urls, at: index)
        })
        lastSent = (text, images)
        do {
            try session.send(text, images: images, context: context?() ?? "", skill: skill(calledBy: text))
            if session.isRunning { setStatus("Working…", busy: true) }
            setBusy(true)
            transcript.showThinking()
        } catch let error as AgentSetupError {
            // A CLI that can't be found or run is fixed in Settings.
            addError(error.message, action: openSettings)
            endSession()
            showIdle()
        } catch {
            addError((error as? ControlError)?.message ?? error.localizedDescription, action: tryAgain)
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
        // An unloaded chat has nothing new; writing would empty its file.
        guard conversation != nil, recordsLoaded else { return }
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
        let room = max(0, AgentAttachment.maxCount - composer.attachments.count - pendingAttachments)
        let sources = images.prefix(room).compactMap(AttachmentSource.init)
        if sources.count < images.count { NSSound.beep() }
        guard !sources.isEmpty else { return }
        // Scaling and encoding a screenshot takes a moment, so it happens
        // off the main thread and the thumbnails follow.
        pendingAttachments += sources.count
        let folder = folder
        Task { [weak self] in
            let added = await Task.detached(priority: .userInitiated) {
                sources.compactMap { AgentAttachment(source: $0, in: folder) }
            }.value
            guard let self else { return }
            self.pendingAttachments -= sources.count
            if added.count < sources.count { NSSound.beep() }
            self.composer.attachments += added
        }
    }

    /// Images still being encoded, which count against the limit.
    private var pendingAttachments = 0

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
        case .skills(let skills):
            loadedSkills = skills
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
            // The agent is deciding what to do with the result.
            if toolRows.isEmpty, isBusy { transcript.showThinking() }
        case .retrying:
            setStatus("Retrying…", busy: true)
        case .error(let message):
            addError(message)
        case .turnFinished(let error, let stopped):
            keepLiveText()
            transcript.hideThinking()
            transcript.closeToolGroup()
            if let error { addError(error, action: tryAgain) }
            if stopped { addNote("Stopped") }
            showIdle()
            readTitle()
        case .exited(let message):
            keepLiveText()
            finishToolRows()
            transcript.hideThinking()
            transcript.closeToolGroup()
            if resuming {
                // The saved session couldn't be continued, so start over.
                conversation?.sessionID = nil
                if let conversation { save(conversation) }
                addError((message ?? "\(kind.displayName) couldn't continue this chat.")
                    + "\nThe next message starts a new conversation, without what was said before.", action: tryAgain)
            } else if let message {
                addError(message + "\nThe next message continues the conversation.", action: tryAgain)
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
        composer.shortPlaceholder = "Ask \(kind.displayName)…"
        emptyState.kind = kind
        emptyState.isHidden = !transcript.isEmpty || !recordsLoaded
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

    /// `action` offers a way out under the message, such as Try Again. It
    /// shows only now; a saved error has none.
    private func addError(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        records.append(.error(message))
        saveRecords()
        transcript.add(ErrorMessageView(text: message, action: action))
    }

    /// The last message sent, for trying again after a failure.
    private var lastSent: (text: String, images: [AgentAttachment])?

    /// Sends the last message again, unless a turn is running.
    private var tryAgain: (title: String, run: () -> Void)? {
        guard let lastSent else { return nil }
        return ("Try Again", { [weak self] in
            guard let self, !self.isBusy else { return }
            self.send(lastSent.text, images: lastSent.images)
        })
    }

    /// Opens the Agent pane, where a missing CLI's path is set.
    private var openSettings: (title: String, run: () -> Void) {
        ("Open Settings…", { (NSApp.delegate as? AppDelegate)?.showAgentSettings() })
    }

    /// Draws a saved row.
    private func show(_ record: AgentRecord, thumbnails: Thumbnails) {
        switch record {
        case .user(let text, let names):
            let loaded = names.compactMap { name in thumbnails.images[name].map { (folder.appendingPathComponent(name), $0) } }
            let urls = loaded.map(\.0)
            transcript.add(UserMessageView(text: text, images: loaded.map(\.1)) { [weak self] index in
                self?.preview(urls, at: index)
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
        clip.scroll(to: NSPoint(x: 0, y: bottomOffset))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The clip's origin with the last message just above the bottom inset.
    /// The clip spans the insets too, so the top rests at minus the top inset.
    private var bottomOffset: CGFloat {
        let clipHeight = scrollView.contentView.bounds.height
        return max(-Self.insets.top, transcript.frame.height - clipHeight + Self.insets.bottom)
    }
}

/// A strip over one edge of the transcript that fades from the panel's
/// background to clear. It only draws: clicks and scrolls pass through.
final class EdgeFadeView: NSView {
    enum Edge { case top, bottom }
    static let height: CGFloat = 10
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// The panel draws nothing of its own, so it shows the window's
    /// background. Resolved here, where the view's appearance is current, so
    /// it follows light and dark mode.
    override func updateLayer() {
        guard let gradient = layer as? CAGradientLayer else { return }
        // Opaque at the edge, clear toward the transcript. Layer y runs up.
        gradient.startPoint = CGPoint(x: 0.5, y: edge == .top ? 1 : 0)
        gradient.endPoint = CGPoint(x: 0.5, y: edge == .top ? 0 : 1)
        gradient.colors = [
            NSColor.windowBackgroundColor.cgColor,
            NSColor.windowBackgroundColor.withAlphaComponent(0).cgColor,
        ]
    }
}

/// A round button with a down arrow that floats over the transcript while
/// the newest message is out of view. It fades in and out.
final class ScrollDownButton: NSButton {
    private var shown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Scroll to Newest")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .accessoryBarAction
        contentTintColor = .labelColor
        toolTip = "Scroll to Newest"
        alphaValue = 0
        isHidden = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        if show { isHidden = false }
        let reduceMotion = Theme.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Theme.Duration.standard
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.isHidden = true
            }
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }
        layer.cornerRadius = 15
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.borderWidth = Theme.hairlineWidth
        layer.borderColor = Theme.hairline.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }
}
