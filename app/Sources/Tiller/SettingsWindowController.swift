import AppKit
import UniformTypeIdentifiers

/// The Settings window (Cmd+,), with General, Passwords, Extensions, Agent and
/// Profiles panes. Every change is saved as it is made, in the current profile.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init() {
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
            (PasswordsSettingsPane(), "key"),
            (ExtensionsSettingsPane(), "puzzlepiece.extension"),
            (AgentSettingsPane(), "sparkles"),
            (ProfilesSettingsPane(), "person.2"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: ScrollingPaneController(pane))
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

    func showPane(titled title: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.viewController?.title == title }) {
            tabs.selectedTabViewItemIndex = index
        }
    }

    /// Cmd+W is File > Close Tab, which otherwise only browser windows answer.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

/// Holds a pane in a scroll view, so a pane taller than the screen scrolls
/// instead of pushing the window off it. The window takes the pane's own
/// size whenever it fits.
@MainActor
final class ScrollingPaneController: NSViewController {
    private let pane: NSViewController

    init(_ pane: NSViewController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
        title = pane.title
        addChild(pane)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A flipped document starts scrolled to the top, not the bottom.
        let document = FlippedView()
        document.addSubview(pane.view)
        scroll.documentView = document
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            pane.view.topAnchor.constraint(equalTo: document.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            pane.view.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])
        view = scroll
        fit()
    }

    // The pane gets its own viewWillAppear from the containment.
    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// The pane's size, with the height held to what the screen has room for.
    private func fit() {
        var size = pane.preferredContentSize
        if size == .zero { size = pane.view.fittingSize }
        let screen = view.window?.screen ?? NSScreen.main
        if let screen {
            // Room under the title bar and toolbar, with a margin.
            let room = screen.visibleFrame.height - 140
            size.height = min(size.height, max(300, room))
        }
        preferredContentSize = size
    }
}

/// A view whose origin is its top left, for a scroll view's document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
        // Sets the note's control apart from the one that follows.
        row.bottomPadding = 6
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A note of up to two lines that wraps within `width`, for under a
    /// table. It keeps room for both, since the pane is sized once.
    static func wrappingNote(width: CGFloat) -> NSTextField {
        let label = note()
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = width
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return label
    }

    static func show(_ text: String, in note: NSTextField, warning: Bool = false) {
        note.stringValue = text
        note.textColor = warning ? .systemRed : .secondaryLabelColor
    }

    /// `scroll` with a dimmed label over the middle of its rows, for a table
    /// with no rows. Hide the label while there are rows.
    static func withPlaceholder(_ scroll: NSScrollView, _ text: String) -> (box: NSView, label: NSTextField) {
        let box = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        for view in [scroll, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        let header = scroll.documentView.flatMap { ($0 as? NSTableView)?.headerView?.frame.height } ?? 0
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -header / 2),
        ])
        return (box, label)
    }

    static func fixWidth(_ view: NSView, _ width: CGFloat = controlWidth) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    static func popUp<T: RawRepresentable<String>>(
        _ cases: [T], title: (T) -> String, image: ((T) -> NSImage?)? = nil, selected: T, target: AnyObject,
        action: Selector
    ) -> NSPopUpButton where T: Equatable {
        let button = NSPopUpButton()
        for value in cases {
            button.addItem(withTitle: title(value))
            button.lastItem?.representedObject = value.rawValue
            button.lastItem?.image = image?(value)
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
    private var tabLayoutPopUp: NSPopUpButton?
    private var searchPopUp: NSPopUpButton?
    private let templateField = NSTextField()
    private let templateNote = SettingsPane.note()
    private let defaultBrowserButton = NSButton(title: "Make Default", target: nil, action: nil)
    private let defaultBrowserStatus = NSTextField(labelWithString: "")

    init() { super.init(title: "General") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        defaultBrowserButton.target = self
        defaultBrowserButton.action = #selector(makeDefaultBrowser(_:))
        let defaultBrowser = NSStackView(views: [defaultBrowserButton, defaultBrowserStatus])
        defaultBrowser.spacing = 8
        addRow("Default browser:", defaultBrowser)
        addNote(Self.note("For every profile. Links open in the profile used last."))
        showDefaultBrowserState()
        for name in [NSApplication.didBecomeActiveNotification, .defaultBrowserDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(defaultBrowserChanged(_:)), name: name, object: nil
            )
        }

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

        let tabLayoutPopUp = Self.popUp(
            TabLayout.allCases, title: \.displayName, selected: Settings.tabLayout,
            target: self, action: #selector(tabLayoutChanged(_:))
        )
        self.tabLayoutPopUp = tabLayoutPopUp
        addRow("Show tabs:", tabLayoutPopUp)

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
        showDefaultBrowserState()
        homepageField.stringValue = Settings.homepage
        templateField.stringValue = Settings.searchTemplate
        launchPopUp?.selectItem(at: LaunchTabs.allCases.firstIndex(of: Settings.launchTabs) ?? 0)
        newTabPopUp?.selectItem(at: NewTabPage.allCases.firstIndex(of: Settings.newTabPage) ?? 0)
        tabLayoutPopUp?.selectItem(at: TabLayout.allCases.firstIndex(of: Settings.tabLayout) ?? 0)
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

    @objc private func makeDefaultBrowser(_ sender: NSButton) {
        DefaultBrowser.makeDefault { [weak self] _ in self?.showDefaultBrowserState() }
    }

    /// Another app may have taken over as the default while Tiller was in the background.
    @objc private func defaultBrowserChanged(_ notification: Notification) {
        showDefaultBrowserState()
    }

    private func showDefaultBrowserState() {
        let isDefault = DefaultBrowser.isDefault
        defaultBrowserButton.isHidden = isDefault
        defaultBrowserButton.isEnabled = DefaultBrowser.isAvailable
        defaultBrowserStatus.stringValue = isDefault
            ? "Tiller is the default browser."
            : DefaultBrowser.isAvailable ? "" : "Only Tiller.app can be the default."
    }

    @objc private func launchTabsChanged(_ sender: NSPopUpButton) {
        guard let tabs = (sender.selectedItem?.representedObject as? String).flatMap(LaunchTabs.init) else { return }
        Settings.launchTabs = tabs
    }

    @objc private func newTabPageChanged(_ sender: NSPopUpButton) {
        guard let page = (sender.selectedItem?.representedObject as? String).flatMap(NewTabPage.init) else { return }
        Settings.newTabPage = page
    }

    @objc private func tabLayoutChanged(_ sender: NSPopUpButton) {
        guard let layout = (sender.selectedItem?.representedObject as? String).flatMap(TabLayout.init) else { return }
        Settings.tabLayout = layout
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
/// remove logins. Passwords come in through Tiller > Import from Chrome.
final class PasswordsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let copyButton = NSButton(title: "Copy Password", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All…", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: 560)
    private var placeholder: NSTextField?
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
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Saved Passwords")
        self.placeholder = placeholder

        copyButton.target = self
        copyButton.action = #selector(copyPassword(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll(_:))
        let buttons = NSStackView(views: [copyButton, removeButton, NSView(), removeAllButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
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
        placeholder?.isHidden = !entries.isEmpty
        SettingsPane.show(
            entries.isEmpty
                ? "No saved passwords. Bring them over with Tiller > Import from Chrome…"
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
        alert.informativeText = "Removes \(entries.count) passwords from Tiller. Chrome keeps its own."
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

// MARK: Extensions

/// The profile's extensions, with switches to turn them on and pin them to
/// the toolbar, and buttons to add, configure and remove them. Chromium loads
/// extensions at launch, so turning one on or off applies at the next launch.
final class ExtensionsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let paneTitle = "Extensions"

    private let table = NSTableView()
    private let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let addCRXButton = NSButton(title: "Add CRX File…", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: 600)
    private var placeholder: NSTextField?
    private var store: ExtensionStore { .shared }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [
            ("on", "On", 30.0), ("name", "Extension", 250.0), ("version", "Version", 80.0),
            ("pinned", "Toolbar", 56.0), ("status", "Status", 140.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openOptions(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Extensions")
        self.placeholder = placeholder

        for (button, action) in [
            (addFolderButton, #selector(addFolder(_:))),
            (addCRXButton, #selector(addCRX(_:))),
            (optionsButton, #selector(openOptions(_:))),
            (removeButton, #selector(remove(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addFolderButton, addCRXButton, optionsButton, NSView(), removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 600),
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
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .extensionsDidChange, object: nil)
        reload(nil)
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected.filteredIndexSet { $0 < store.entries.count }, byExtendingSelection: false)
        updateControls()
    }

    private func updateControls() {
        optionsButton.isEnabled = selectedManifest?.optionsURL != nil
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        placeholder?.isHidden = !store.entries.isEmpty
        let text: String
        if store.entries.isEmpty {
            text = "No extensions. Add an unpacked folder or a CRX file, or bring Chrome's over with Tiller > Import from Chrome…"
        } else if store.needsRestart {
            text = "Changes apply the next time Tiller opens."
        } else {
            text = "\(store.running.count) of \(store.entries.count) running. Chrome's tab and window APIs don't see Tiller's tabs."
        }
        SettingsPane.show(text, in: note)
    }

    /// The selected extension, when exactly one is selected and running.
    private var selectedManifest: ExtensionManifest? {
        guard table.selectedRowIndexes.count == 1, store.entries.indices.contains(table.selectedRow) else { return nil }
        let entry = store.entries[table.selectedRow]
        guard store.isLoaded(entry), store.loadError(forFolder: entry.path) == nil else { return nil }
        return try? store.manifest(for: entry).get()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard store.entries.indices.contains(row) else { return nil }
        let entry = store.entries[row]
        let manifest = store.manifest(for: entry)
        switch column?.identifier.rawValue {
        case "on", "pinned":
            let isOn = column?.identifier.rawValue == "on"
            let checkbox = NSButton(
                checkboxWithTitle: "", target: self, action: isOn ? #selector(toggleEnabled(_:)) : #selector(togglePinned(_:)))
            checkbox.tag = row
            checkbox.state = (isOn ? entry.enabled : entry.pinned) ? .on : .off
            return checkbox
        case "name":
            let label = NSTextField(labelWithString: (try? manifest.get().name) ?? (entry.path as NSString).lastPathComponent)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = entry.path
            let icon = NSImageView(image: (try? manifest.get().image(size: 16))
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)!)
            let stack = NSStackView(views: [icon, label])
            stack.spacing = 6
            return stack
        case "version":
            return NSTextField(labelWithString: (try? manifest.get().version) ?? "")
        default:
            let label = NSTextField(labelWithString: status(of: entry, manifest))
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            if case .failure(let error) = manifest {
                label.textColor = .systemRed
                label.toolTip = error.localizedDescription
            } else if store.isLoaded(entry), let error = store.loadError(forFolder: entry.path) {
                label.textColor = .systemRed
                label.toolTip = error
            }
            return label
        }
    }

    private func status(of entry: ExtensionStore.Entry, _ manifest: Result<ExtensionManifest, Error>) -> String {
        if case .failure(let error) = manifest {
            if case ExtensionError.noManifest = error { return "Folder missing" }
            return "Can't be loaded"
        }
        if store.isLoaded(entry) && store.loadError(forFolder: entry.path) != nil {
            return "Failed to load"
        }
        switch (store.isLoaded(entry), entry.enabled) {
        case (true, true): return "Running"
        case (true, false): return "Stops at next launch"
        case (false, true): return "Starts at next launch"
        case (false, false): return "Off"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        store.setEnabled(sender.state == .on, at: sender.tag)
    }

    @objc private func togglePinned(_ sender: NSButton) {
        store.setPinned(sender.state == .on, at: sender.tag)
    }

    @objc private func addFolder(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose an unpacked extension's folder, the one with manifest.json in it"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    let manifest = try self.store.addFolder(url.path)
                    SettingsPane.show("Added \(manifest.name). It starts the next time Tiller opens.", in: self.note)
                } catch {
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }

    @objc private func addCRX(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "crx") ?? .data]
        panel.message = "Choose a Chrome extension package"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    do {
                        let manifest = try await self.store.addCRX(url.path)
                        SettingsPane.show("Added \(manifest.name). It starts the next time Tiller opens.", in: self.note)
                    } catch {
                        SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                    }
                }
            }
        }
    }

    @objc private func openOptions(_ sender: Any?) {
        guard let url = selectedManifest?.optionsURL else { return }
        (NSApp.delegate as? AppDelegate)?.openInNewTab(url)
    }

    @objc private func remove(_ sender: Any?) {
        store.remove(at: table.selectedRowIndexes)
        table.deselectAll(nil)
    }
}

// MARK: Agent

final class AgentSettingsPane: SettingsPane, NSTextFieldDelegate, NSTextViewDelegate {
    private var agentPopUp: NSPopUpButton?
    /// Picks which CLI's path `pathField` shows.
    private var pathKindPopUp: NSPopUpButton?
    private let pathField = NSTextField()
    private let pathNote = SettingsPane.note()
    /// What the lookup found, for kinds whose lookup has finished. Nil values mean not found.
    private var detected: [AgentKind: String?] = [:]
    /// The CLI whose path is being edited.
    private var pathKind: AgentKind {
        (pathKindPopUp?.selectedItem?.representedObject as? String).flatMap(AgentKind.init) ?? .current
    }
    private var instructionsView: NSTextView?
    private let folderField = NSTextField()
    private let folderNote = SettingsPane.note()
    private let shortcutRecorder = ShortcutRecorder()
    private lazy var restoreShortcutButton = NSButton(
        title: "Restore Default", target: self, action: #selector(restoreShortcut(_:))
    )
    private let shortcutNote = SettingsPane.note()

    /// Paths need more room than General's controls.
    private static let wideControlWidth: CGFloat = 460

    init() { super.init(title: "Agent") }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let popUp = Self.popUp(
            AgentKind.allCases, title: \.displayName, image: { $0.logo(size: 16) }, selected: .current,
            target: self, action: #selector(agentChanged(_:))
        )
        agentPopUp = popUp
        addRow("New chats use:", popUp)
        addNote(Self.note("A running chat keeps its agent."))
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )

        let tabsPopUp = NSPopUpButton()
        for count in Settings.agentTabsRange {
            tabsPopUp.addItem(withTitle: "\(count)")
            tabsPopUp.lastItem?.tag = count
        }
        tabsPopUp.selectItem(withTag: Settings.agentTabs)
        tabsPopUp.target = self
        tabsPopUp.action = #selector(tabsChanged(_:))
        addRow("Chat tabs:", tabsPopUp)
        addNote(Self.note("At most this many chats open at once. The rest stay in history."))

        shortcutRecorder.shortcut = Settings.agentShortcut
        shortcutRecorder.onRecord = { [weak self] shortcut in self?.shortcutRecorded(shortcut) }
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let shortcutRow = NSStackView(views: [shortcutRecorder, restoreShortcutButton])
        shortcutRow.spacing = 8
        addRow("Show and hide:", shortcutRow)
        addNote(shortcutNote)
        showShortcutState()

        // One row serves every CLI: the popup picks whose path the field shows.
        let kindPopUp = Self.popUp(
            AgentKind.allCases, title: \.displayName, image: { $0.logo(size: 16) }, selected: .current,
            target: self, action: #selector(pathKindChanged(_:))
        )
        pathKindPopUp = kindPopUp
        pathField.delegate = self
        let choosePath = NSButton(title: "Choose…", target: self, action: #selector(choosePath(_:)))
        let pathRow = NSStackView(views: [kindPopUp, pathField, choosePath])
        pathRow.spacing = 8
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addRow("Run:", Self.fixWidth(pathRow, Self.wideControlWidth))
        addNote(pathNote)
        loadPathField()

        let checkboxes = AgentTool.allCases.enumerated().map { index, tool in
            let checkbox = NSButton(checkboxWithTitle: tool.displayName, target: self, action: #selector(toolChanged(_:)))
            checkbox.tag = index
            checkbox.state = Settings.agentToolEnabled(tool) ? .on : .off
            return checkbox
        }
        let tools = NSStackView(views: checkboxes)
        tools.orientation = .vertical
        tools.alignment = .leading
        tools.spacing = 6
        let toolsRow = addRow("Also allow:", tools)
        toolsRow.rowAlignment = .none
        toolsRow.cell(at: 0).yPlacement = .top
        let toolsNote = Self.note(
            "They run without asking, and pages can try to steer the agent. Codex always reads and runs "
                + "read-only commands. Defaults for new chats; each chat can change its own from the tools button."
        )
        toolsNote.lineBreakMode = .byWordWrapping
        toolsNote.preferredMaxLayoutWidth = Self.wideControlWidth
        addNote(toolsNote)

        folderField.stringValue = Settings.agentFolder
        folderField.placeholderString = "An empty folder"
        folderField.delegate = self
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        let folderRow = NSStackView(views: [Self.fixWidth(folderField, Self.wideControlWidth - 90), choose])
        folderRow.spacing = 8
        addRow("Work in:", folderRow)
        addNote(folderNote)
        showFolderState()

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // A rounded box like the text fields above it.
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .labelColor.withAlphaComponent(0.04)
        box.contentViewMargins = NSSize(width: 1, height: 1)
        box.contentView = scroll
        box.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let textView = scroll.documentView as! NSTextView
        textView.drawsBackground = false
        textView.string = Settings.agentInstructions
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = self
        instructionsView = textView
        let row = addRow("Extra instructions:", Self.fixWidth(box, Self.wideControlWidth))
        row.rowAlignment = .none
        row.cell(at: 0).yPlacement = .top
        addNote(Self.note("Added after Tiller's prompt. Applies from the next new chat."))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadPathField()
        detectPaths()
    }

    /// Looks up each CLI off the main thread, since it may start a login shell.
    private func detectPaths() {
        Task { [weak self] in
            for kind in AgentKind.allCases {
                let path = await Task.detached { AgentEnvironment.detectedExecutable(for: kind) }.value
                guard let self else { return }
                self.detected[kind] = .some(path)
                self.showPathState()
            }
        }
    }

    /// Shows the picked CLI's path in the field.
    private func loadPathField() {
        pathField.stringValue = Settings.defaults.string(forKey: pathKind.pathDefaultsKey) ?? ""
        showPathState()
    }

    @objc private func pathKindChanged(_ sender: NSPopUpButton) {
        loadPathField()
    }

    private func showPathState() {
        let kind = pathKind
        let found = detected[kind]
        pathField.placeholderString = switch found {
        case .none: "Looking for \(kind.rawValue)…"
        case .some(let path?): path
        case .some(nil): "\(kind.rawValue) not found"
        }
        if let path = Settings.agentPath(for: kind) {
            if FileManager.default.isExecutableFile(atPath: path) {
                Self.show("Tiller runs this file for \(kind.displayName).", in: pathNote)
            } else {
                Self.show("Not an executable file.", in: pathNote, warning: true)
            }
        } else if case .some(nil) = found {
            Self.show("Not found. Install \(kind.displayName), or choose its file.", in: pathNote, warning: true)
        } else {
            Self.show("Leave empty to find it automatically.", in: pathNote)
        }
    }

    private func showFolderState() {
        guard let folder = Settings.agentFolderPath else {
            Self.show("Leave empty so no project's files or instructions load.", in: folderNote)
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue {
            Self.show("Its instructions and project settings load too.", in: folderNote)
        } else {
            Self.show("Not a folder.", in: folderNote, warning: true)
        }
    }

    @objc private func toolChanged(_ sender: NSButton) {
        guard AgentTool.allCases.indices.contains(sender.tag) else { return }
        Settings.setAgentTool(AgentTool.allCases[sender.tag], enabled: sender.state == .on)
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose the folder the agent works in"
        if let current = Settings.agentFolderPath { panel.directoryURL = URL(fileURLWithPath: current) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.folderField.stringValue = url.path
                Settings.agentFolder = url.path
                self.showFolderState()
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === folderField {
            Settings.agentFolder = folderField.stringValue
            showFolderState()
            return
        }
        guard notification.object as? NSTextField === pathField else { return }
        Settings.setAgentPath(pathField.stringValue, for: pathKind)
        showPathState()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = instructionsView else { return }
        Settings.agentInstructions = textView.string
    }

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let kind = (sender.selectedItem?.representedObject as? String).flatMap(AgentKind.init) else { return }
        AgentKind.current = kind
    }

    @objc private func tabsChanged(_ sender: NSPopUpButton) {
        Settings.agentTabs = sender.selectedTag()
    }

    private func shortcutRecorded(_ shortcut: Shortcut?) {
        if let shortcut {
            if shortcut.modifiers.isDisjoint(with: [.command, .control]) {
                return Self.show("Use a combination with ⌘ or ⌃.", in: shortcutNote, warning: true)
            }
            if let title = MainMenu.conflict(with: shortcut) {
                return Self.show("\(shortcut.displayString) is used by \(title).", in: shortcutNote, warning: true)
            }
        }
        Settings.agentShortcut = shortcut
        MainMenu.applyAgentShortcut()
        showShortcutState()
    }

    @objc private func restoreShortcut(_ sender: Any?) {
        Settings.resetAgentShortcut()
        MainMenu.applyAgentShortcut()
        showShortcutState()
    }

    private func showShortcutState() {
        shortcutRecorder.shortcut = Settings.agentShortcut
        restoreShortcutButton.isEnabled = Settings.agentShortcut != Settings.defaultAgentShortcut
        Self.show(
            Settings.agentShortcut == nil
                ? "No shortcut. Click to record one."
                : "Click to record another. Delete clears it, Escape cancels.",
            in: shortcutNote
        )
    }

    /// The panel's picker changed the agent.
    @objc private func currentAgentChanged(_ notification: Notification) {
        agentPopUp?.selectItem(at: AgentKind.allCases.firstIndex(of: .current) ?? 0)
    }

    @objc private func choosePath(_ sender: NSButton) {
        guard let window = view.window else { return }
        let kind = pathKind
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
                Settings.setAgentPath(url.path, for: kind)
                if self.pathKind == kind { self.loadPathField() }
            }
        }
    }
}

// MARK: Profiles

/// Every profile, with buttons to open, add, rename and delete them. Each open
/// profile is a separate Tiller.
final class ProfilesSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let paneTitle = "Profiles"

    private let table = NSTableView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let addButton = NSButton(title: "New Profile…", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: 560)
    private var profiles: [Profile] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("name", "Name", 320.0), ("status", "Status", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openProfile(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [
            (openButton, #selector(openProfile(_:))),
            (addButton, #selector(addProfile(_:))),
            (renameButton, #selector(renameProfile(_:))),
            (deleteButton, #selector(deleteProfile(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [openButton, addButton, renameButton, NSView(), deleteButton])
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
            scroll.heightAnchor.constraint(equalToConstant: 220),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .profilesDidChange, object: nil)
        reload(nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload(nil)
    }

    @objc private func reload(_ notification: Notification?) {
        let selectedID = selectedProfile?.id
        profiles = Profiles.all
        table.reloadData()
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateControls()
    }

    private var selectedProfile: Profile? {
        profiles.indices.contains(table.selectedRow) ? profiles[table.selectedRow] : nil
    }

    private func updateControls() {
        let selected = selectedProfile
        openButton.isEnabled = selected != nil
        renameButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected.map { $0.id != Profiles.current.id } ?? false
        SettingsPane.show(
            "Each profile keeps its own cookies, history, tabs, passwords, settings and chats, "
                + "and opens as a separate Tiller.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]
        let text: String
        if column?.identifier.rawValue == "name" {
            text = profile.name
        } else if profile.id == Profiles.current.id {
            text = "This window"
        } else {
            text = Profiles.runningProcess(profile.id) != nil ? "Open" : ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if column?.identifier.rawValue == "status" { label.textColor = .secondaryLabelColor }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func openProfile(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        Profiles.open(profile.id)
    }

    @objc private func addProfile(_ sender: Any?) {
        ProfileNamePrompt.run("New Profile", button: "Create", on: view.window) { name in
            Profiles.open(try Profiles.create(named: name).id)
        }
    }

    @objc private func renameProfile(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        ProfileNamePrompt.run("Rename \(profile.name)", button: "Rename", initial: profile.name, on: view.window) { name in
            try Profiles.rename(profile.id, to: name)
        }
    }

    @objc private func deleteProfile(_ sender: Any?) {
        guard let window = view.window, let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "Its cookies, history, tabs, passwords, settings and chats go too. "
            + "Its folder moves to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                do {
                    try Profiles.delete(profile.id)
                } catch {
                    guard let self else { return }
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }
}
