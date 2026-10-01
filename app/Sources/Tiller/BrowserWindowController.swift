import AppKit

/// One window holding the tabs. With tabs along the top, the toolbar has
/// back, forward, reload, the tabs, a new-tab button, extension buttons, the
/// profile's name when there are several, and the agent panel toggle, and the
/// address bar sits in a row under it. With tabs in a sidebar, the address
/// bar takes the tabs' place in the toolbar, and the page is a card between
/// the sidebar on the left and the agent panel on the right.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSSplitViewDelegate, TabDelegate, TabStripDelegate, AgentPanelDelegate
{
    var onClose: (() -> Void)?

    private let splitView = ChromeSplitView()
    private var tabLayout = Settings.tabLayout
    /// Holds the tabs while they are vertical. Hidden otherwise.
    private let sidebar = TabSidebarView()
    /// The sidebar's width while it isn't collapsed.
    private var sidebarWidth = TabSidebarView.defaultWidth
    private lazy var sidebarMinWidth = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private lazy var sidebarMaxWidth = sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
    /// Holds every tab's view. The selected one is on top, and the others are
    /// hidden unless an agent woke them.
    private let contentView = PageCardView()
    private let agentPanel = AgentPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
    /// Where the panel is going. It stays unhidden while it slides out.
    private var agentPanelShown = Settings.defaults.bool(forKey: BrowserWindowController.agentVisibleKey)
    /// Counts toggles, so a slide's completion knows a later toggle took over.
    private var agentToggleCount = 0
    private let agentButton = NSButton()
    /// A dot on the agent button while a chat works behind a hidden panel.
    private let agentBadge = NSView()
    private let tabStrip = TabStripView()
    private let addressBar = AddressBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let newTabButton = NSButton()
    /// Names the profile and opens the Profiles menu. Hidden with one profile.
    private let profileButton = NSButton()
    private var profileItem: NSToolbarItem?
    /// Extension buttons. Hidden when no extension is loaded.
    private let extensionBar = ExtensionBarView()
    /// The extension popup while one is open.
    private var extensionPopover: ExtensionPopover?
    /// Nil while there is only one profile.
    private var profileName: String?
    private lazy var suggestions = AddressSuggestions(addressBar: addressBar)
    private lazy var findBar: FindBar = {
        let bar = FindBar()
        bar.onChange = { [weak self] text in self?.find(text) }
        bar.onStep = { [weak self] forward in self?.findAgain(forward: forward) }
        bar.onClose = { [weak self] in self?.hideFindBar(focusPage: true) }
        return bar
    }()
    /// Shown over the selected tab while it is blank.
    private lazy var startPage: StartPageView = {
        let view = StartPageView()
        view.onOpen = { [weak self] url in self?.openSuggestion(url) }
        return view
    }()
    /// The import sheet while it is up.
    private var chromeImport: ChromeImportController?

    /// The tab strip's width, kept to what the toolbar has room for. A larger
    /// preference makes the toolbar move the whole strip into its overflow menu.
    private lazy var tabStripWidth = tabStrip.widthAnchor.constraint(equalToConstant: 600)
    private lazy var tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 28)
    /// The address bar's size in the toolbar, fitted like the tab strip's.
    private lazy var addressWidth = addressBar.widthAnchor.constraint(equalToConstant: 600)
    private lazy var addressHeight = addressBar.heightAnchor.constraint(equalToConstant: 30)
    /// Holds the address bar while the tabs are along the top.
    private var addressAccessory: NSTitlebarAccessoryViewController?

    private var tabs: [Tab] = []
    private var selectedTab: Tab?
    /// Set while every tab closes for a quit or the window closing, so the
    /// session saved just before keeps them all. A page that cancels its
    /// beforeunload leaves tabs open, and the next thing done with the tabs
    /// clears it.
    private var closingAll = false
    /// Tabs an agent woke, each with the timer that hides it again.
    private var wakeTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// How long a tab stays awake after an agent's last click, type or screenshot.
    private static let wakeDuration: TimeInterval = 30

    /// Opens the `restored` tabs, then `url` in a selected tab after them. With
    /// no `url`, selects the restored tab at `selected`. One of the two must
    /// give at least one tab.
    init(restoring restored: [SessionStore.SavedTab], selected: Int, opening url: String?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiller"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.setFrameAutosaveName("TillerBrowserWindow")
        super.init(window: window)

        window.delegate = self
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentView)
        splitView.addArrangedSubview(agentPanel)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        // Above the page, so the sidebar and the panel keep their widths when
        // the window resizes, and under the priority of a divider drag (490),
        // which must win.
        splitView.setHoldingPriority(.init(270), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 2)
        splitView.delegate = self
        sidebarMinWidth.isActive = true
        sidebarMaxWidth.isActive = true
        sidebar.isHidden = tabLayout != .vertical
        sidebar.isCollapsed = Settings.sidebarCollapsed
        let savedWidth = Settings.defaults.double(forKey: Self.sidebarWidthKey)
        if savedWidth > 0 { sidebarWidth = savedWidth }
        agentPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        agentPanel.delegate = self
        agentPanel.isHidden = !agentPanelShown
        agentPanel.wantsLayer = true
        // Not the name used while there were two panes, whose saved widths
        // don't fit three.
        splitView.autosaveName = "TillerSplit"
        window.contentView = splitView
        window.toolbarStyle = .unified

        if !window.setFrameUsingName("TillerBrowserWindow") { window.center() }

        configureControls()
        tabStrip.delegate = self
        applyTabLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(passwordsChanged(_:)), name: .passwordsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tabLayoutChanged(_:)), name: .tabLayoutDidChange, object: nil)
        // Restored tabs load when first selected.
        for saved in restored {
            openTab(url: saved.isBlank ? "about:blank" : saved.url, select: false, restoring: saved, lazily: true)
        }
        if let url {
            openTab(url: url, select: true)
        } else {
            select(tabs[min(max(selected, 0), tabs.count - 1)])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tabs

    /// Opens `url` in a new tab at `index`, or at the end. A `restoring` tab
    /// shows its saved title and isn't saved to history again. A tab opened
    /// `lazily` loads when it is first selected, and the caller updates the
    /// tab strip.
    @discardableResult
    private func openTab(
        url: String, select: Bool, at index: Int? = nil, restoring saved: SessionStore.SavedTab? = nil,
        lazily: Bool = false
    ) -> Tab {
        closingAll = false
        let tab = Tab()
        tab.delegate = self
        if let saved { tab.recordedVisit = (saved.url, saved.title) }
        let panelHadFocus = agentPanel.hasKeyboardFocus
        tabs.insert(tab, at: min(index ?? tabs.endIndex, tabs.endIndex))

        window?.layoutIfNeeded()
        tab.hostView.frame = contentView.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        tab.hostView.isHidden = true
        // Under the find bar, which shares this view.
        contentView.addSubview(tab.hostView, positioned: .below, relativeTo: nil)
        if lazily {
            tab.prepare(url: url, title: saved?.title ?? "")
            return tab
        }
        tab.start(url: url, title: saved?.title ?? "")

        if select {
            self.select(tab)
        } else {
            tabStrip.update(tabs: tabs, selected: selectedTab)
            saveSession()
        }
        // An agent opening a tab shouldn't take the keyboard from its panel.
        if panelHadFocus { window?.makeFirstResponder(agentPanel.input) }
        return tab
    }

    /// `resumeSaving` is false only when a closing tab hands the selection on.
    private func select(_ tab: Tab, resumeSaving: Bool = true) {
        if resumeSaving { closingAll = false }
        if tab !== selectedTab { hideFindBar(focusPage: false) }
        if let old = selectedTab, !isAwake(old) { old.hostView.isHidden = true }
        // Over the tabs an agent keeps awake. The find bar closed above.
        if tab !== selectedTab { contentView.addSubview(tab.hostView, positioned: .above, relativeTo: nil) }
        selectedTab = tab
        tab.hostView.isHidden = false
        start(tab)
        tabStrip.update(tabs: tabs, selected: tab)
        showState(of: tab)
        addressBar.setProgress(tab.progress, loading: tab.isLoading, animated: false)
        saveSession()
        if tab.isBlank {
            openLocation(nil)
        } else {
            tab.focus()
        }
    }

    /// Starts a restored tab's browser, if it is still waiting.
    private func start(_ tab: Tab) {
        guard !tab.isStarted else { return }
        tab.hostView.frame = contentView.bounds
        tab.startIfNeeded()
    }

    /// Keeps a tab drawing behind the selected one for `wakeDuration`, so an
    /// agent can click, type and take screenshots in it. Chromium treats a
    /// hidden view's page as hidden: it stops drawing, and input to it stalls
    /// for seconds or is dropped. A covered view counts as visible.
    private func wake(_ tab: Tab) -> Bool {
        start(tab)
        let woke = tab.hostView.isHidden
        if woke {
            // Under the selected tab. Views are moved only while hidden: sorting
            // them all made Chromium count every hidden page as visible again.
            contentView.addSubview(tab.hostView, positioned: .below, relativeTo: nil)
            tab.hostView.isHidden = false
        }
        let key = ObjectIdentifier(tab)
        wakeTimers[key]?.cancel()
        let sleep = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.wakeTimers[ObjectIdentifier(tab)] = nil
                if tab !== self.selectedTab { tab.hostView.isHidden = true }
            }
        }
        wakeTimers[key] = sleep
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDuration, execute: sleep)
        return woke
    }

    private func isAwake(_ tab: Tab) -> Bool {
        wakeTimers[ObjectIdentifier(tab)] != nil
    }

    /// Asks a tab to close on the user's or an agent's behalf.
    private func requestClose(_ tab: Tab) {
        closingAll = false
        tab.close()
    }

    /// Takes the tab out of the window once CEF has agreed to close it.
    private func remove(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        wakeTimers.removeValue(forKey: ObjectIdentifier(tab))?.cancel()
        tab.detach()
        // Tearing down the view is what lets CEF finish closing the browser.
        tab.hostView.removeFromSuperview()
        tabs.remove(at: index)

        // The window closes and Tiller quits with it. The session saved before
        // still has this tab, so the next launch reopens it.
        guard !tabs.isEmpty else {
            selectedTab = nil
            tabStrip.update(tabs: [], selected: nil)
            window?.close()
            return
        }
        if !closingAll && !tab.isBlank {
            SessionStore.shared.pushClosedTab(.init(url: tab.url, title: tab.title), at: index)
        }
        if tab === selectedTab {
            selectedTab = nil
            let next = tabs[min(index, tabs.count - 1)]
            // While every tab closes, a tab that never loaded is left alone:
            // selecting it would start its browser, which keeps Tiller running
            // after the others are gone.
            if closingAll && !next.isStarted {
                tabStrip.update(tabs: tabs, selected: nil)
            } else {
                select(next, resumeSaving: false)
            }
        } else {
            tabStrip.update(tabs: tabs, selected: selectedTab)
            saveSession()
        }
    }

    /// Records the tabs for the next launch. Does nothing while they all close.
    private func saveSession() {
        guard !closingAll else { return }
        let selected = selectedTab.flatMap { selected in tabs.firstIndex { $0 === selected } } ?? 0
        SessionStore.shared.setOpenTabs(tabs.map { .init(url: $0.url, title: $0.title) }, selected: selected)
    }

    /// Saves the session as it stands and stops saving while every tab closes,
    /// so the next launch gets them all back.
    func freezeSession() {
        saveSession()
        closingAll = true
        SessionStore.shared.flush()
    }

    private func showState(of tab: Tab) {
        addressBar.show(tab.url)
        showLoading(tab.isLoading)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        window?.title = tab.displayTitle
        addressBar.keyButton.isHidden = savedLogins(for: tab).isEmpty
        addressBar.showZoom(tab.zoomFactor)
        updateStartPage(for: tab)
    }

    /// Puts the start page over `tab` while it is blank, and takes it away once
    /// the tab goes somewhere.
    private func updateStartPage(for tab: Tab) {
        if tab.isBlank {
            guard startPage.superview !== tab.hostView else { return }
            startPage.frame = tab.hostView.bounds
            startPage.autoresizingMask = [.width, .height]
            tab.hostView.addSubview(startPage, positioned: .above, relativeTo: nil)
            startPage.reload()
        } else if startPage.superview === tab.hostView {
            startPage.removeFromSuperview()
        }
    }

    /// Saves the page to history once it has loaded, and again whenever its
    /// URL or title changes after that.
    private func recordHistory(_ tab: Tab) {
        guard tab.url.hasPrefix("http://") || tab.url.hasPrefix("https://") else { return }
        if let icon = tab.faviconPNG, icon != tab.recordedIcon {
            HistoryStore.shared.setIcon(icon, for: tab.url)
            tab.recordedIcon = icon
        }
        guard !tab.isLoading else { return }
        if tab.recordedVisit?.url != tab.url {
            HistoryStore.shared.recordVisit(url: tab.url, title: tab.title)
        } else if tab.recordedVisit?.title != tab.title {
            HistoryStore.shared.setTitle(tab.title, for: tab.url)
        } else {
            return
        }
        tab.recordedVisit = (tab.url, tab.title)
    }

    // MARK: TabDelegate

    func tabDidChange(_ tab: Tab) {
        recordHistory(tab)
        saveSession()
        tabStrip.refresh(tab)
        if tab === selectedTab {
            showState(of: tab)
            addressBar.setProgress(tab.progress, loading: tab.isLoading)
        }
    }

    func tab(_ tab: Tab, foundMatches count: Int, active: Int, final: Bool) {
        guard tab === selectedTab, findBar.superview != nil, !findBar.text.isEmpty else { return }
        findBar.showCount((count, active))
    }

    func tabProgressChanged(_ tab: Tab) {
        if tab === selectedTab { addressBar.setProgress(tab.progress, loading: tab.isLoading) }
    }

    func tab(_ tab: Tab, openInNewTab url: String, background: Bool) {
        openTab(url: url, select: !background, at: tabs.firstIndex { $0 === tab }.map { $0 + 1 })
    }

    func tabReadyToClose(_ tab: Tab) {
        remove(tab)
    }

    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool {
        performMenuKeyEquivalent(event)
    }

    /// Menu shortcuts win over the page, except the Edit menu's, so editors in
    /// the page keep their own undo, select all and so on.
    private func performMenuKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let menu = NSApp.mainMenu else { return false }
        for item in menu.items {
            // Of the Edit menu, only Find goes before the page.
            let submenu = item.submenu?.title == MainMenu.editTitle
                ? item.submenu?.item(withTitle: MainMenu.findTitle)?.submenu : item.submenu
            if submenu?.performKeyEquivalent(with: event) == true { return true }
        }
        return false
    }

    // MARK: TabStripDelegate

    func tabStrip(_ strip: TabStripView, select tab: Tab) {
        if tab !== selectedTab { select(tab) }
    }

    func tabStrip(_ strip: TabStripView, close tab: Tab) {
        requestClose(tab)
    }

    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), tabs.indices.contains(index) else { return }
        closingAll = false
        tabs.insert(tabs.remove(at: from), at: index)
        tabStrip.update(tabs: tabs, selected: selectedTab)
        saveSession()
    }

    func tabStripNewTab(_ strip: TabStripView) {
        newTab(nil)
    }

    // MARK: Actions (also reached from the menu through the responder chain)

    @objc func newTab(_ sender: Any?) {
        openTab(url: Settings.newTabPage == .homepage ? Settings.homepageURL : "about:blank", select: true)
    }

    /// Opens `url` in a new selected tab and brings the window forward.
    func openInNewTab(_ url: String) {
        openTab(url: url, select: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func closeTab(_ sender: Any?) {
        if let selectedTab { requestClose(selectedTab) }
    }

    /// Cmd+Shift+T: opens the last closed tab where it was.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = SessionStore.shared.popClosedTab() else { return }
        openTab(url: closed.tab.url, select: true, at: closed.index, restoring: closed.tab)
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

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { zoom(1) }
    @objc func zoomOut(_ sender: Any?) { zoom(-1) }
    @objc func actualSize(_ sender: Any?) { zoom(0) }

    private func zoom(_ step: Int32) {
        guard let tab = selectedTab else { return }
        tab.zoom(step)
        // Chromium applies the zoom on its next turn.
        DispatchQueue.main.async { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, tab === self.selectedTab else { return }
                self.addressBar.showZoom(tab.zoomFactor)
            }
        }
    }

    // MARK: Find

    @objc func showFindBar(_ sender: Any?) {
        guard selectedTab != nil else { return }
        if findBar.superview == nil {
            findBar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(findBar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                findBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                findBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            ])
            if !findBar.text.isEmpty { find(findBar.text) }
        }
        window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
    }

    @objc func findNext(_ sender: Any?) { findAgain(forward: true) }
    @objc func findPrevious(_ sender: Any?) { findAgain(forward: false) }

    private func find(_ text: String) {
        guard let tab = selectedTab else { return }
        if text.isEmpty {
            tab.stopFinding()
            findBar.showCount(nil)
        } else {
            tab.find(text)
        }
    }

    private func findAgain(forward: Bool) {
        guard let tab = selectedTab, !findBar.text.isEmpty else { return showFindBar(nil) }
        if findBar.superview == nil { showFindBar(nil) }
        tab.find(findBar.text, forward: forward, next: true)
    }

    private func hideFindBar(focusPage: Bool) {
        guard findBar.superview != nil else { return }
        findBar.removeFromSuperview()
        selectedTab?.stopFinding()
        findBar.showCount(nil)
        if focusPage { selectedTab?.focus() }
    }

    /// Slides the panel in or out. The page resizes once, before sliding in and
    /// after sliding out, since Chromium laying it out every frame would stutter.
    @objc func toggleAgentPanel(_ sender: Any?) {
        agentPanelShown.toggle()
        Settings.defaults.set(agentPanelShown, forKey: Self.agentVisibleKey)
        agentButton.state = agentPanelShown ? .on : .off
        updateAgentBadge()
        agentToggleCount += 1
        let count = agentToggleCount
        roundPage()
        if agentPanelShown {
            agentPanel.isHidden = false
            splitView.adjustSubviews()
            window?.makeFirstResponder(agentPanel.input)
            slideAgentPanel(to: 0, count: count)
        } else {
            selectedTab?.focus()
            slideAgentPanel(to: agentPanel.bounds.width, count: count) { [weak self] in
                self?.agentPanel.isHidden = true
                self?.splitView.adjustSubviews()
            }
        }
    }

    /// Moves the panel from wherever it is now to `offset` points right of its
    /// place, then runs `completion` unless another toggle came first.
    private func slideAgentPanel(to offset: CGFloat, count: Int, completion: (() -> Void)? = nil) {
        guard let layer = agentPanel.layer else {
            completion?()
            return
        }
        let key = "slide"
        let current = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
        // Coming out of hiding, start off the right edge.
        let start = layer.animation(forKey: key) == nil
            ? (offset == 0 ? agentPanel.bounds.width : 0) : current ?? 0
        layer.removeAnimation(forKey: key)
        let finish = { [weak self] in
            guard let self, self.agentToggleCount == count else { return }
            completion?()
            layer.removeAnimation(forKey: key)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return finish()
        }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = offset
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: offset == 0 ? .easeOut : .easeIn)
        // Stays at the end until `finish` hides the panel, so it doesn't flash back.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        layer.add(animation, forKey: key)
        CATransaction.commit()
    }

    /// The dot shows only while the panel is hidden, where the work would
    /// otherwise go unseen.
    private func updateAgentBadge() {
        let shown = agentPanel.isBusy && !agentPanelShown
        agentBadge.isHidden = !shown
        guard shown else { return }
        agentBadge.effectiveAppearance.performAsCurrentDrawingAppearance {
            agentBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    private static let agentVisibleKey = "agentPanelVisible"
    private static let sidebarWidthKey = "sidebarWidth"

    #if DEBUG
    /// For testing without typing: `open Tiller.app --args -agentPrompt "..."`.
    /// `-agentPasteImage YES` pastes the clipboard twice first.
    func sendAgentPrompt(_ text: String) {
        if !agentPanelShown { toggleAgentPanel(nil) }
        if UserDefaults.standard.bool(forKey: "agentPasteImage") {
            agentPanel.pasteAndSendForTesting(text)
        } else {
            agentPanel.send(text)
        }
        let stopAfter = UserDefaults.standard.double(forKey: "agentStopAfter")
        if stopAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { [weak self] in
                MainActor.assumeIsolated { self?.agentPanel.stopForTesting() }
            }
        }
    }
    #endif

    @objc func openLocation(_ sender: Any?) {
        // Already editing: keep what was typed and select it.
        if !addressBar.field.isEditing { window?.makeFirstResponder(addressBar.field) }
        addressBar.field.currentEditor()?.selectAll(nil)
    }

    /// Loads a suggestion picked from the address bar's list.
    private func openSuggestion(_ url: String) {
        guard let tab = selectedTab else { return }
        tab.load(url)
        addressBar.show(url)
        tab.focus()
    }

    @objc private func addressEntered(_ sender: NSTextField) {
        let input = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let tab = selectedTab else { return }
        let url = AddressInput.url(for: input)
        tab.load(url)
        addressBar.show(url)
        tab.focus()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAgentPanel(_:)) {
            item.title = agentPanelShown ? "Hide Agent" : "Show Agent"
        }
        return switch item.action {
        case #selector(goBack(_:)): selectedTab?.canGoBack ?? false
        case #selector(goForward(_:)): selectedTab?.canGoForward ?? false
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): tabs.count > 1
        case #selector(reopenClosedTab(_:)): SessionStore.shared.hasClosedTabs
        case #selector(fillPassword(_:)): selectedTab.map { !savedLogins(for: $0).isEmpty } ?? false
        case #selector(findNext(_:)), #selector(findPrevious(_:)): !findBar.text.isEmpty
        case #selector(actualSize(_:)): selectedTab.map { abs($0.zoomFactor - 1) > 0.001 } ?? false
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)): selectedTab != nil
        // A blank tab has nothing to find in.
        case #selector(showFindBar(_:)): selectedTab.map { !$0.isBlank } ?? false
        default: true
        }
    }

    // MARK: Window

    /// Closes every tab first. Each page's beforeunload may still cancel its own
    /// close. The window closes when its last tab is gone.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.isEmpty { return true }
        closeAllTabs()
        return false
    }

    /// Closes every tab, for the window closing or Tiller quitting. Tabs that
    /// never loaded go right away; the others run their beforeunload first. The
    /// window closes with the last one, and Tiller quits with the window.
    func closeAllTabs() {
        freezeSession()
        tabs.forEach { $0.close() }
    }

    func windowDidResize(_ notification: Notification) {
        suggestions.hide()
        fitTabStrip()
    }

    /// Room left after the window buttons, back, forward, reload, new tab, the
    /// extension buttons, the profile button and the agent button. The address
    /// bar gets the same in the tabs' place, plus the new-tab button's.
    private func fitTabStrip() {
        guard let width = window?.frame.width else { return }
        let profileWidth = profileName == nil ? 0 : profileButton.fittingSize.width + 12
        let extensionsWidth = extensionBar.isEmpty ? 0 : extensionBar.fittingSize.width + 12
        tabStripWidth.constant = max(200, width - 370 - profileWidth - extensionsWidth)
        addressWidth.constant = max(200, width - 330 - profileWidth - extensionsWidth)
    }

    // MARK: Tab layout

    @objc private func tabLayoutChanged(_ notification: Notification) {
        guard Settings.tabLayout != tabLayout else { return }
        tabLayout = Settings.tabLayout
        applyTabLayout()
        if let selectedTab { tabStrip.update(tabs: tabs, selected: selectedTab) }
    }

    /// Puts the tabs and the address bar where `tabLayout` has them.
    private func applyTabLayout() {
        guard let window else { return }
        let vertical = tabLayout == .vertical
        suggestions.hide()
        if let addressAccessory, let index = window.titlebarAccessoryViewControllers.firstIndex(of: addressAccessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        addressAccessory = nil
        // Sizes that only hold in the toolbar.
        tabStripWidth.isActive = !vertical
        tabStripHeight.isActive = !vertical
        addressWidth.isActive = vertical
        addressHeight.isActive = vertical
        addressBar.inset = vertical ? 0 : 12
        tabStrip.orientation = vertical ? .vertical : .horizontal

        // A toolbar per layout, since the items differ.
        let toolbar = NSToolbar(identifier: vertical ? "TillerToolbarSidebar" : "TillerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if vertical {
            sidebar.show(tabStrip)
        } else {
            addressBar.frame.size.height = 40
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = addressBar
            accessory.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(accessory)
            addressAccessory = accessory
        }
        window.titlebarSeparatorStyle = vertical ? .none : .automatic
        splitView.hidesDividers = vertical
        sidebar.isHidden = !vertical
        roundPage()
        fitSidebar()
        fitTabStrip()
    }

    /// With tabs in the sidebar the page is a card, rounded where it meets
    /// the sidebar and the agent panel.
    private func roundPage() {
        contentView.isCard = tabLayout == .vertical
        contentView.roundsTrailingCorner = agentPanelShown
    }

    /// Gives the sidebar its collapsed width, or the one it had before.
    private func fitSidebar() {
        let collapsed = sidebar.isCollapsed
        let range = TabSidebarView.widthRange
        let width = collapsed
            ? TabSidebarView.collapsedWidth : min(max(sidebarWidth, range.lowerBound), range.upperBound)
        // Apart first, so the two never cross on the way.
        sidebarMinWidth.constant = 0
        sidebarMaxWidth.constant = collapsed ? width : range.upperBound
        sidebarMinWidth.constant = collapsed ? width : range.lowerBound
        guard !sidebar.isHidden else { return splitView.adjustSubviews() }
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(width, ofDividerAt: 0)
    }

    @objc private func toggleSidebarCollapsed(_ sender: Any?) {
        sidebar.isCollapsed.toggle()
        Settings.sidebarCollapsed = sidebar.isCollapsed
        fitSidebar()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !sidebar.isHidden, !sidebar.isCollapsed, sidebar.frame.width != sidebarWidth,
            TabSidebarView.widthRange.contains(sidebar.frame.width)
        else { return }
        sidebarWidth = sidebar.frame.width
        Settings.defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    private func showLoading(_ loading: Bool) {
        reloadButton.image = NSImage(
            systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
        reloadButton.toolTip = loading ? "Stop" : "Reload"
    }

    /// Shows the profile's name in the toolbar and window title, or hides it
    /// when `name` is nil.
    func showProfile(name: String?) {
        profileName = name
        profileButton.title = name ?? ""
        profileItem?.isHidden = name == nil
        window?.title = name.map { "Tiller – \($0)" } ?? "Tiller"
        fitTabStrip()
    }

    @objc private func showProfilesMenu(_ sender: NSButton) {
        MainMenu.profiles.popUp(
            positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender
        )
    }

    func windowWillClose(_ notification: Notification) {
        extensionPopover?.close()
        agentPanel.shutDown()
        SessionStore.shared.flush()
        onClose?()
    }

    // MARK: Toolbar

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let reload = NSToolbarItem.Identifier("reload")
        static let tabs = NSToolbarItem.Identifier("tabs")
        static let address = NSToolbarItem.Identifier("address")
        static let newTab = NSToolbarItem.Identifier("newTab")
        static let agent = NSToolbarItem.Identifier("agent")
        static let profile = NSToolbarItem.Identifier("profile")
        static let extensions = NSToolbarItem.Identifier("extensions")
    }

    private func configureControls() {
        for (button, name, tip, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack(_:))),
            (forwardButton, "chevron.right", "Forward", #selector(goForward(_:))),
            (reloadButton, "arrow.clockwise", "Reload", #selector(reloadOrStop(_:))),
            (newTabButton, "plus", "New Tab", #selector(newTab(_:))),
            (agentButton, "sparkles", "Agent", #selector(toggleAgentPanel(_:))),
        ] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
            button.toolTip = tip
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        profileButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profile")
        profileButton.imagePosition = .imageLeading
        profileButton.toolTip = "Profiles"
        profileButton.bezelStyle = .toolbar
        profileButton.target = self
        profileButton.action = #selector(showProfilesMenu(_:))
        agentButton.setButtonType(.pushOnPushOff)
        agentButton.state = agentPanel.isHidden ? .off : .on
        agentBadge.wantsLayer = true
        agentBadge.layer?.cornerRadius = 3.5
        agentBadge.isHidden = true
        agentBadge.translatesAutoresizingMaskIntoConstraints = false
        agentButton.addSubview(agentBadge)
        NSLayoutConstraint.activate([
            agentBadge.widthAnchor.constraint(equalToConstant: 7),
            agentBadge.heightAnchor.constraint(equalToConstant: 7),
            agentBadge.topAnchor.constraint(equalTo: agentButton.topAnchor, constant: 3),
            agentBadge.trailingAnchor.constraint(equalTo: agentButton.trailingAnchor, constant: -3),
        ])
        agentPanel.onBusyChange = { [weak self] _ in self?.updateAgentBadge() }

        addressBar.field.target = self
        addressBar.field.action = #selector(addressEntered(_:))
        sidebar.collapseButton.target = self
        sidebar.collapseButton.action = #selector(toggleSidebarCollapsed(_:))
        addressBar.keyButton.target = self
        addressBar.keyButton.action = #selector(fillPassword(_:))
        addressBar.zoomButton.target = self
        addressBar.zoomButton.action = #selector(actualSize(_:))
        suggestions.onOpen = { [weak self] url in self?.openSuggestion(url) }
        extensionBar.onPopup = { [weak self] manifest, anchor in self?.showExtensionPopup(manifest, from: anchor) }
        extensionBar.onOpen = { [weak self] url in self?.openInNewTab(url) }
        extensionBar.onResize = { [weak self] in self?.fitTabStrip() }
    }

    /// Opens the extension's popup under `anchor`, closing any other first.
    /// Clicking the button of the one that's open just closes it.
    private func showExtensionPopup(_ manifest: ExtensionManifest, from anchor: NSView) {
        if let open = extensionPopover {
            open.close()
            if open.manifest.id == manifest.id { return }
        }
        let popover = ExtensionPopover(manifest: manifest)
        popover.onOpenTab = { [weak self, weak popover] url, background in
            guard let self else { return }
            self.openTab(url: url, select: !background)
            if !background { popover?.close() }
        }
        popover.onKeyEquivalent = { [weak self] event in self?.performMenuKeyEquivalent(event) ?? false }
        popover.onClose = { [weak self, weak popover] in
            if let self, self.extensionPopover === popover { self.extensionPopover = nil }
        }
        extensionPopover = popover
        popover.show(relativeTo: anchor)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabLayout == .vertical
            ? [Item.back, Item.forward, Item.reload, Item.address, .flexibleSpace, Item.extensions, Item.profile, Item.agent]
            : [
                Item.back, Item.forward, Item.reload, Item.tabs, Item.newTab, .flexibleSpace, Item.extensions,
                Item.profile, Item.agent,
            ]
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
        case Item.reload: item.view = reloadButton; item.label = "Reload"
        case Item.newTab: item.view = newTabButton; item.label = "New Tab"
        case Item.agent: item.view = agentButton; item.label = "Agent"
        case Item.extensions:
            item.view = extensionBar
            item.label = "Extensions"
            item.isHidden = extensionBar.isEmpty
        case Item.profile:
            item.view = profileButton
            item.label = "Profile"
            item.isHidden = profileName == nil
            profileItem = item
        case Item.tabs:
            item.view = tabStrip
            item.label = "Tabs"
            fitTabStrip()
        case Item.address:
            item.view = addressBar
            item.label = "Address"
            // The bar draws its own capsule; without this the toolbar would
            // put a second piece of glass around it and the buttons before it.
            item.isBordered = false
            fitTabStrip()
        default: return nil
        }
        return item
    }
}

// MARK: Control socket

extension BrowserWindowController {
    /// Tab operations for tiller_mcp. Tab ids are CEF browser ids, the same ids
    /// the core's DevTools calls take. A missing `tab_id` means the selected tab.
    func control(_ method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "tabs.list":
            // Tab ids are browser ids, so every listed tab needs its browser.
            tabs.forEach(start)
            return ["tabs": tabs.map(info)]
        case "tabs.new":
            let url = (params["url"] as? String).map(AddressInput.url(for:)) ?? "about:blank"
            return info(openTab(url: url, select: params["select"] as? Bool ?? true))
        case "tabs.select":
            let tab = try tab(for: params)
            if tab !== selectedTab {
                let panelHadFocus = agentPanel.hasKeyboardFocus
                select(tab)
                if panelHadFocus { window?.makeFirstResponder(agentPanel.input) }
            }
            return info(tab)
        case "tabs.wake":
            // Before a click, type or screenshot. `woke` says the page was hidden
            // until now, so it may need a moment to draw.
            let tab = try tab(for: params)
            var reply = info(tab)
            reply["woke"] = wake(tab)
            return reply
        case "tabs.navigate":
            let tab = try tab(for: params)
            guard let input = params["url"] as? String, !input.isEmpty else { throw ControlError("navigate needs a url") }
            tab.load(AddressInput.url(for: input))
            tabDidChange(tab)
            return info(tab)
        case "tabs.close":
            let tab = try tab(for: params)
            requestClose(tab)
            return ["closing": Int(tab.browserID)]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    private func tab(for params: [String: Any]) throws -> Tab {
        guard let id = params["tab_id"] as? Int else {
            guard let selectedTab else { throw ControlError("no tab is open") }
            return selectedTab
        }
        guard let tab = tabs.first(where: { Int($0.browserID) == id }) else { throw ControlError("no tab with id \(id)") }
        return tab
    }

    private func info(_ tab: Tab) -> [String: Any] {
        [
            "id": Int(tab.browserID),
            "url": tab.url,
            "title": tab.displayTitle,
            "loading": tab.isLoading,
            "selected": tab === selectedTab,
        ]
    }
}

// MARK: Agent panel

extension BrowserWindowController {
    func agentPanelContext(_ panel: AgentPanelView) -> String {
        guard let tab = selectedTab else { return "[Tiller: no tab is open]" }
        return "[Tiller: selected tab \(tab.browserID), \"\(tab.displayTitle)\", \(tab.isBlank ? "about:blank" : tab.url)]"
    }

    /// Widens the divider's grab area into the panel. The divider is a point
    /// wide, and the page beside it takes the mouse for itself.
    func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        if dividerIndex == 0 {
            // The sidebar's divider, grabbed from the sidebar's side.
            guard !sidebar.isHidden, !sidebar.isCollapsed else { return .zero }
            return NSRect(x: drawnRect.minX - 6, y: drawnRect.minY, width: drawnRect.width + 6, height: drawnRect.height)
        }
        guard !agentPanel.isHidden else { return .zero }
        return NSRect(x: drawnRect.minX, y: drawnRect.minY, width: drawnRect.width + 6, height: drawnRect.height)
    }
}

// MARK: History, passwords and import

extension BrowserWindowController {
    /// A page from the History menu. The URL is the item's represented object.
    @objc func openHistoryItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? String else { return }
        guard let tab = selectedTab else { return }
        tab.load(url)
        tab.focus()
        tabDidChange(tab)
    }

    @objc func clearHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Removes every page from Tiller's history, including pages imported from Chrome, and forgets recently closed tabs. Cookies and saved passwords stay."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.clear()
            MainActor.assumeIsolated {
                SessionStore.shared.clearClosedTabs()
                // So each open tab saves its favicon again.
                self.tabs.forEach { $0.recordedIcon = nil }
            }
        }
    }

    @objc func importFromChrome(_ sender: Any?) {
        guard let window, chromeImport == nil else { return }
        let controller = ChromeImportController()
        chromeImport = controller
        controller.begin(on: window) { [weak self] in self?.chromeImport = nil }
    }

    /// Fills the page's saved login. With several, asks which one from a menu
    /// under the key button.
    @objc func fillPassword(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let logins = savedLogins(for: tab)
        if logins.count == 1 { return fill(logins[0], in: tab) }
        guard !logins.isEmpty else { return }
        let menu = NSMenu()
        for login in logins {
            let item = MenuActionItem(title: login.username.isEmpty ? "(no username)" : login.username) { [weak self] in
                self?.fill(login, in: tab)
            }
            menu.addItem(item)
        }
        let button = addressBar.keyButton
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
    }

    private func savedLogins(for tab: Tab) -> [PasswordStore.Entry] {
        SavedLogin.origin(of: tab.url).map(PasswordStore.shared.logins(for:)) ?? []
    }

    private func fill(_ login: PasswordStore.Entry, in tab: Tab) {
        Task {
            do {
                let password = try await PasswordStore.shared.password(for: login)
                guard tabs.contains(where: { $0 === tab }) else { return }
                tab.executeJavaScript(LoginFill.script(origin: login.origin, username: login.username, password: password))
            } catch {
                guard let window else { return }
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    @objc private func passwordsChanged(_ notification: Notification) {
        if let selectedTab { showState(of: selectedTab) }
    }
}

/// Holds the tabs' pages. As a card its top corners are rounded where it
/// meets the sidebar and the agent panel, and a hairline sets it apart from
/// them, which a light page on the light window would otherwise run into.
final class PageCardView: NSView {
    var isCard = false { didSet { needsDisplay = true } }
    /// Whether the corner next to the agent panel is rounded too.
    var roundsTrailingCorner = false {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    private let outline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        outline.fillColor = nil
        outline.lineWidth = 1
        // Above the pages, which are sublayers too.
        outline.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = isCard ? 10 : 0
        layer.masksToBounds = isCard
        layer.maskedCorners = roundsTrailingCorner
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner]
        outline.isHidden = !isCard
        outline.strokeColor = NSColor.separatorColor.cgColor
        if outline.superlayer == nil { layer.addSublayer(outline) }
    }

    override func layout() {
        super.layout()
        // The top and the sides next to the sidebar and the panel. The bottom
        // and an open side are the window's edge.
        let radius: CGFloat = 10
        let inset: CGFloat = 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: 0))
        path.addLine(to: CGPoint(x: inset, y: bounds.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: bounds.maxY - inset), control: CGPoint(x: inset, y: bounds.maxY - inset))
        if roundsTrailingCorner {
            path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY - inset))
            path.addQuadCurve(
                to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - radius),
                control: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
            path.addLine(to: CGPoint(x: bounds.maxX - inset, y: 0))
        } else {
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - inset))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = path
        CATransaction.commit()
    }
}

/// A menu item that runs a closure.
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { handler() }
}
