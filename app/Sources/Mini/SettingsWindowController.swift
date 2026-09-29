import AppKit

/// The Settings window (Cmd+,), with General, Passwords and Agent panes.
/// Every change is saved as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
            (PasswordsSettingsPane(), "key"),
            (AgentSettingsPane(), "sparkles"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Cmd+W is File > Close Tab, which otherwise only browser windows answer.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

/// A two-column form: right-aligned labels, controls on the right, and short
/// notes under some controls.
@MainActor
class SettingsPane: NSViewController {
    let grid = NSGridView()
    static let controlWidth: CGFloat = 360

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        buildRows()
        grid.column(at: 0).xPlacement = .trailing
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Subclasses add their rows here.
    func buildRows() {}

    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        grid.addRow(with: [NSTextField(labelWithString: label), control])
    }

    /// A note under the control in the row above.
    func addNote(_ note: NSTextField) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -4
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func show(_ text: String, in note: NSTextField, warning: Bool = false) {
        note.stringValue = text
        note.textColor = warning ? .systemRed : .secondaryLabelColor
    }

    static func fixWidth(_ view: NSView, _ width: CGFloat = controlWidth) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    static func popUp<T: RawRepresentable<String>>(
        _ cases: [T], title: (T) -> String, selected: T, target: AnyObject, action: Selector
    ) -> NSPopUpButton where T: Equatable {
        let button = NSPopUpButton()
        for value in cases {
            button.addItem(withTitle: title(value))
            button.lastItem?.representedObject = value.rawValue
        }
        button.selectItem(at: cases.firstIndex(of: selected) ?? 0)
        button.target = target
        button.action = action
        return button
    }
}

// MARK: General

final class GeneralSettingsPane: SettingsPane, NSTextFieldDelegate {
    private let homepageField = NSTextField()
    private var launchPopUp: NSPopUpButton?
    private var newTabPopUp: NSPopUpButton?
    private var searchPopUp: NSPopUpButton?
    private let templateField = NSTextField()
    private let templateNote = SettingsPane.note()

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        homepageField.stringValue = Settings.homepage
        homepageField.placeholderString = Settings.defaultHomepage
        homepageField.delegate = self
        addRow("Homepage:", Self.fixWidth(homepageField))
        addNote(Self.note("Opens at launch and in new tabs, as chosen below."))

        let launchPopUp = Self.popUp(
            LaunchTabs.allCases, title: \.displayName, selected: Settings.launchTabs,
            target: self, action: #selector(launchTabsChanged(_:))
        )
        self.launchPopUp = launchPopUp
        addRow("At launch, open:", launchPopUp)

        let newTabPopUp = Self.popUp(
            NewTabPage.allCases, title: \.displayName, selected: Settings.newTabPage,
            target: self, action: #selector(newTabPageChanged(_:))
        )
        self.newTabPopUp = newTabPopUp
        addRow("New tabs open with:", newTabPopUp)

        let searchPopUp = Self.popUp(
            SearchEngine.allCases, title: \.displayName, selected: Settings.searchEngine,
            target: self, action: #selector(searchEngineChanged(_:))
        )
        self.searchPopUp = searchPopUp
        addRow("Search engine:", searchPopUp)

        templateField.stringValue = Settings.searchTemplate
        templateField.placeholderString = "https://example.com/search?q=%s"
        templateField.delegate = self
        addRow("Custom search URL:", Self.fixWidth(templateField))
        addNote(templateNote)
        showTemplateState()
    }

    /// An import from Chrome may have changed these while the window was closed.
    override func viewWillAppear() {
        super.viewWillAppear()
        homepageField.stringValue = Settings.homepage
        templateField.stringValue = Settings.searchTemplate
        launchPopUp?.selectItem(at: LaunchTabs.allCases.firstIndex(of: Settings.launchTabs) ?? 0)
        newTabPopUp?.selectItem(at: NewTabPage.allCases.firstIndex(of: Settings.newTabPage) ?? 0)
        searchPopUp?.selectItem(at: SearchEngine.allCases.firstIndex(of: Settings.searchEngine) ?? 0)
        showTemplateState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === homepageField {
            Settings.homepage = field.stringValue
        } else if field === templateField {
            Settings.searchTemplate = field.stringValue
            showTemplateState()
        }
    }

    @objc private func launchTabsChanged(_ sender: NSPopUpButton) {
        guard let tabs = (sender.selectedItem?.representedObject as? String).flatMap(LaunchTabs.init) else { return }
        Settings.launchTabs = tabs
    }

    @objc private func newTabPageChanged(_ sender: NSPopUpButton) {
        guard let page = (sender.selectedItem?.representedObject as? String).flatMap(NewTabPage.init) else { return }
        Settings.newTabPage = page
    }

    @objc private func searchEngineChanged(_ sender: NSPopUpButton) {
        guard let engine = (sender.selectedItem?.representedObject as? String).flatMap(SearchEngine.init) else { return }
        Settings.searchEngine = engine
        showTemplateState()
        if engine == .custom { view.window?.makeFirstResponder(templateField) }
    }

    private func showTemplateState() {
        let custom = Settings.searchEngine == .custom
        templateField.isEnabled = custom
        if custom && !Settings.isValidSearchTemplate(Settings.searchTemplate) {
            Self.show("Needs an http(s) URL with %s. Google is used until then.", in: templateNote, warning: true)
        } else {
            Self.show("Put %s where the search terms go.", in: templateNote)
        }
    }
}

// MARK: Passwords

/// Saved passwords: site and username, with buttons to copy a password or
/// remove logins. Passwords come in through File > Import from Chrome.
final class PasswordsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let copyButton = NSButton(title: "Copy Password", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All…", target: nil, action: nil)
    private let note = SettingsPane.note()
    private var entries: [PasswordStore.Entry] { PasswordStore.shared.entries }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Passwords"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("site", "Website", 300.0), ("username", "Username", 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        copyButton.target = self
        copyButton.action = #selector(copyPassword(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll(_:))
        let buttons = NSStackView(views: [copyButton, removeButton, NSView(), removeAllButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 560),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .passwordsDidChange, object: nil)
        reload(nil)
    }

    @objc private func reload(_ notification: Notification?) {
        table.reloadData()
        updateControls()
    }

    private func updateControls() {
        copyButton.isEnabled = table.selectedRowIndexes.count == 1
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        removeAllButton.isEnabled = !entries.isEmpty
        SettingsPane.show(
            entries.isEmpty
                ? "No saved passwords. Bring them over with File > Import from Chrome…"
                : "\(entries.count) saved. On a page with a saved login, the key in the address bar fills it.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let text = column?.identifier.rawValue == "site"
            ? HistoryStore.bare(entry.origin)
            : (entry.username.isEmpty ? "(no username)" : entry.username)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if column?.identifier.rawValue == "site" { label.toolTip = entry.origin }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    private var selectedEntries: [PasswordStore.Entry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    @objc private func copyPassword(_ sender: Any?) {
        guard let entry = selectedEntries.first else { return }
        Task {
            do {
                let password = try await PasswordStore.shared.password(for: entry)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
                SettingsPane.show("Copied the password for \(HistoryStore.bare(entry.origin)).", in: note)
            } catch {
                SettingsPane.show(error.localizedDescription, in: note, warning: true)
            }
        }
    }

    @objc private func remove(_ sender: Any?) {
        do {
            try PasswordStore.shared.remove(Set(selectedEntries.map(\.id)))
        } catch {
            SettingsPane.show(error.localizedDescription, in: note, warning: true)
        }
    }

    @objc private func removeAll(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all saved passwords?"
        alert.informativeText = "Removes \(entries.count) passwords from Mini. Chrome keeps its own."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                do {
                    try PasswordStore.shared.removeAll()
                } catch {
                    guard let self else { return }
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }
}

// MARK: Agent

final class AgentSettingsPane: SettingsPane, NSTextFieldDelegate, NSTextViewDelegate {
    private var agentPopUp: NSPopUpButton?
    private var pathFields: [AgentKind: NSTextField] = [:]
    private var pathNotes: [AgentKind: NSTextField] = [:]
    /// What the lookup found, for kinds whose lookup has finished. Nil values mean not found.
    private var detected: [AgentKind: String?] = [:]
    private var instructionsView: NSTextView?

    init() { super.init(title: "Agent") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let popUp = Self.popUp(
            AgentKind.allCases, title: \.displayName, selected: .current,
            target: self, action: #selector(agentChanged(_:))
        )
        agentPopUp = popUp
        addRow("New chats use:", popUp)
        addNote(Self.note("A running chat keeps its agent."))
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )

        for (index, kind) in AgentKind.allCases.enumerated() {
            let field = NSTextField()
            field.stringValue = UserDefaults.standard.string(forKey: kind.pathDefaultsKey) ?? ""
            field.delegate = self
            let choose = NSButton(title: "Choose…", target: self, action: #selector(choosePath(_:)))
            choose.tag = index
            let row = NSStackView(views: [Self.fixWidth(field, Self.controlWidth - 90), choose])
            row.spacing = 8
            addRow("\(kind.displayName) path:", row)
            let note = Self.note()
            addNote(note)
            pathFields[kind] = field
            pathNotes[kind] = note
            showPathState(kind)
        }

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let textView = scroll.documentView as! NSTextView
        textView.string = Settings.agentInstructions
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = self
        instructionsView = textView
        let row = addRow("Extra instructions:", Self.fixWidth(scroll))
        row.rowAlignment = .none
        row.cell(at: 0).yPlacement = .top
        addNote(Self.note("Added after Mini's prompt. Applies from the next new chat."))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        detectPaths()
    }

    /// Looks up each CLI off the main thread, since it may start a login shell.
    private func detectPaths() {
        Task { [weak self] in
            for kind in AgentKind.allCases {
                let path = await Task.detached { AgentEnvironment.detectedExecutable(for: kind) }.value
                guard let self else { return }
                self.detected[kind] = .some(path)
                self.showPathState(kind)
            }
        }
    }

    private func showPathState(_ kind: AgentKind) {
        guard let field = pathFields[kind], let note = pathNotes[kind] else { return }
        let found = detected[kind]
        field.placeholderString = switch found {
        case .none: "Looking for \(kind.rawValue)…"
        case .some(let path?): path
        case .some(nil): "\(kind.rawValue) not found"
        }
        if let path = Settings.agentPath(for: kind) {
            if FileManager.default.isExecutableFile(atPath: path) {
                Self.show("Mini runs this file.", in: note)
            } else {
                Self.show("Not an executable file.", in: note, warning: true)
            }
        } else if case .some(nil) = found {
            Self.show("Not found. Install it, or choose its file.", in: note, warning: true)
        } else {
            Self.show("Leave empty to find it automatically.", in: note)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            let kind = pathFields.first(where: { $0.value === field })?.key
        else { return }
        Settings.setAgentPath(field.stringValue, for: kind)
        showPathState(kind)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = instructionsView else { return }
        Settings.agentInstructions = textView.string
    }

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let kind = (sender.selectedItem?.representedObject as? String).flatMap(AgentKind.init) else { return }
        AgentKind.current = kind
    }

    /// The panel's picker changed the agent.
    @objc private func currentAgentChanged(_ notification: Notification) {
        agentPopUp?.selectItem(at: AgentKind.allCases.firstIndex(of: .current) ?? 0)
    }

    @objc private func choosePath(_ sender: NSButton) {
        guard let window = view.window, AgentKind.allCases.indices.contains(sender.tag) else { return }
        let kind = AgentKind.allCases[sender.tag]
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(kind.displayName) executable"
        if let current = Settings.agentPath(for: kind) ?? detected[kind] ?? nil {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pathFields[kind]?.stringValue = url.path
                Settings.setAgentPath(url.path, for: kind)
                self.showPathState(kind)
            }
        }
    }
}
