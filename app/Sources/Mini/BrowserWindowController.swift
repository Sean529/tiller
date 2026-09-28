import AppKit

/// One window holding a row of tabs. The toolbar has back, forward, the tabs
/// and a new-tab button. The address bar sits in a row under it.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, TabDelegate, TabStripDelegate
{
    var onClose: (() -> Void)?

    private let contentView = NSView()
    private let tabStrip = TabStripView()
    private let addressBar = AddressBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let newTabButton = NSButton()

    /// The tab strip's width, kept to what the toolbar has room for. A larger
    /// preference makes the toolbar move the whole strip into its overflow menu.
    private lazy var tabStripWidth = tabStrip.widthAnchor.constraint(equalToConstant: 600)

    private var tabs: [Tab] = []
    private var selectedTab: Tab?

    init(url: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MiniBrowserWindow")
        super.init(window: window)

        window.delegate = self
        window.contentView = contentView
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MiniToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = addressBar
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)

        if !window.setFrameUsingName("MiniBrowserWindow") { window.center() }

        configureControls()
        tabStrip.delegate = self
        openTab(url: url, select: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tabs

    /// Opens `url` in a new tab placed after `after`, or at the end.
    @discardableResult
    private func openTab(url: String, select: Bool, after: Tab? = nil) -> Tab {
        let tab = Tab()
        tab.delegate = self
        let index = after.flatMap { after in tabs.firstIndex { $0 === after } }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)

        window?.layoutIfNeeded()
        tab.hostView.frame = contentView.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        tab.hostView.isHidden = true
        contentView.addSubview(tab.hostView)
        tab.start(url: url)

        if select { self.select(tab) } else { tabStrip.update(tabs: tabs, selected: selectedTab) }
        return tab
    }

    private func select(_ tab: Tab) {
        selectedTab?.hostView.isHidden = true
        selectedTab = tab
        tab.hostView.isHidden = false
        tabStrip.update(tabs: tabs, selected: tab)
        showState(of: tab)
        if tab.isBlank {
            openLocation(nil)
        } else {
            tab.focus()
        }
    }

    /// Takes the tab out of the window once CEF has agreed to close it.
    private func remove(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.detach()
        // Tearing down the view is what lets CEF finish closing the browser.
        tab.hostView.removeFromSuperview()
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            selectedTab = nil
            tabStrip.update(tabs: [], selected: nil)
            window?.close()
            return
        }
        if tab === selectedTab {
            selectedTab = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            tabStrip.update(tabs: tabs, selected: selectedTab)
        }
    }

    private func showState(of tab: Tab) {
        addressBar.show(tab.url)
        addressBar.setLoading(tab.isLoading)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.displayTitle
    }

    // MARK: TabDelegate

    func tabDidChange(_ tab: Tab) {
        tabStrip.refresh(tab)
        if tab === selectedTab { showState(of: tab) }
    }

    func tab(_ tab: Tab, openInNewTab url: String, background: Bool) {
        openTab(url: url, select: !background, after: tab)
    }

    func tabReadyToClose(_ tab: Tab) {
        remove(tab)
    }

    /// Menu shortcuts win over the page, except the Edit menu's, so editors in
    /// the page keep their own undo, select all and so on.
    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool {
        guard let menu = NSApp.mainMenu else { return false }
        for item in menu.items where item.submenu?.title != MainMenu.editTitle {
            if item.submenu?.performKeyEquivalent(with: event) == true { return true }
        }
        return false
    }

    // MARK: TabStripDelegate

    func tabStrip(_ strip: TabStripView, select tab: Tab) {
        if tab !== selectedTab { select(tab) }
    }

    func tabStrip(_ strip: TabStripView, close tab: Tab) {
        tab.close()
    }

    // MARK: Actions (also reached from the menu through the responder chain)

    @objc func newTab(_ sender: Any?) {
        openTab(url: "about:blank", select: true)
    }

    @objc func closeTab(_ sender: Any?) {
        selectedTab?.close()
    }

    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    /// Cmd+1 to Cmd+8 pick that tab, Cmd+9 the last one. The number is the menu item's tag.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag, !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    private func selectTab(offset: Int) {
        guard let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    @objc func goBack(_ sender: Any?) { selectedTab?.goBack() }
    @objc func goForward(_ sender: Any?) { selectedTab?.goForward() }

    @objc func reloadOrStop(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reloadPage(_ sender: Any?) { selectedTab?.reload() }

    @objc func openLocation(_ sender: Any?) {
        window?.makeFirstResponder(addressBar.field)
        addressBar.field.currentEditor()?.selectAll(nil)
    }

    @objc private func addressEntered(_ sender: NSTextField) {
        let input = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let tab = selectedTab else { return }
        let url = AddressInput.url(for: input)
        sender.stringValue = url
        tab.load(url)
        tab.focus()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): selectedTab?.canGoBack ?? false
        case #selector(goForward(_:)): selectedTab?.canGoForward ?? false
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): tabs.count > 1
        default: true
        }
    }

    // MARK: Window

    /// Closes every tab first. Each page's beforeunload may still cancel its own
    /// close. The window closes when its last tab is gone.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.isEmpty { return true }
        tabs.forEach { $0.close() }
        return false
    }

    func windowDidResize(_ notification: Notification) {
        fitTabStrip()
    }

    /// Room left after the window buttons, back, forward and new tab.
    private func fitTabStrip() {
        guard let width = window?.frame.width else { return }
        tabStripWidth.constant = max(200, width - 280)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Toolbar

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let tabs = NSToolbarItem.Identifier("tabs")
        static let newTab = NSToolbarItem.Identifier("newTab")
    }

    private func configureControls() {
        for (button, name, tip, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack(_:))),
            (forwardButton, "chevron.right", "Forward", #selector(goForward(_:))),
            (newTabButton, "plus", "New Tab", #selector(newTab(_:))),
        ] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
            button.toolTip = tip
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        addressBar.field.target = self
        addressBar.field.action = #selector(addressEntered(_:))
        addressBar.reloadButton.target = self
        addressBar.reloadButton.action = #selector(reloadOrStop(_:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.tabs, Item.newTab]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.back: item.view = backButton; item.label = "Back"
        case Item.forward: item.view = forwardButton; item.label = "Forward"
        case Item.newTab: item.view = newTabButton; item.label = "New Tab"
        case Item.tabs:
            item.view = tabStrip
            item.label = "Tabs"
            tabStrip.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tabStripWidth.isActive = true
            fitTabStrip()
        default: return nil
        }
        return item
    }
}
