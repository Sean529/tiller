import AppKit

/// The Settings window (Cmd+,), with a General and an Agent pane. Every change
/// is saved as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
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
    private let templateField = NSTextField()
    private let templateNote = SettingsPane.note()

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        homepageField.stringValue = Settings.homepage
        homepageField.placeholderString = Settings.defaultHomepage
        homepageField.delegate = self
        addRow("Homepage:", Self.fixWidth(homepageField))
        addNote(Self.note("Opens at launch, and in new tabs if set below."))

        addRow("New tabs open with:", Self.popUp(
            NewTabPage.allCases, title: \.displayName, selected: Settings.newTabPage,
            target: self, action: #selector(newTabPageChanged(_:))
        ))

        addRow("Search engine:", Self.popUp(
            SearchEngine.allCases, title: \.displayName, selected: Settings.searchEngine,
            target: self, action: #selector(searchEngineChanged(_:))
        ))

        templateField.stringValue = Settings.searchTemplate
        templateField.placeholderString = "https://example.com/search?q=%s"
        templateField.delegate = self
        addRow("Custom search URL:", Self.fixWidth(templateField))
        addNote(templateNote)
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
