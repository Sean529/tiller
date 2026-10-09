import AppKit

/// The toolbar's extension buttons: one for each pinned extension, then one
/// with a menu of every extension Chromium loaded at launch. Hidden while
/// none is running.
@MainActor
final class ExtensionBarView: NSStackView {
    /// Shows the extension's popup under `anchor`.
    var onPopup: ((ExtensionManifest, NSView) -> Void)?
    /// Opens a URL, such as an options page, in a new tab.
    var onOpen: ((String) -> Void)?
    /// The buttons changed, so the toolbar should make room.
    var onResize: (() -> Void)?

    private let menuButton = NSButton()

    var isEmpty: Bool { ExtensionStore.shared.running.isEmpty }

    init() {
        super.init(frame: .zero)
        spacing = 0
        menuButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        menuButton.toolTip = "Extensions"
        menuButton.bezelStyle = .toolbar
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .extensionsDidChange, object: nil)
        reload(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pinning shows at once. What's loaded only changes at the next launch.
    @objc private func reload(_ notification: Notification?) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let pinned = Set(ExtensionStore.shared.entries.filter(\.pinned).map(\.path))
        for manifest in ExtensionStore.shared.running where pinned.contains(manifest.folder) {
            let button = ExtensionButton(manifest: manifest)
            button.target = self
            button.action = #selector(pinnedClicked(_:))
            button.menu = contextMenu(for: manifest)
            addArrangedSubview(button)
        }
        addArrangedSubview(menuButton)
        onResize?()
    }

    @objc private func pinnedClicked(_ sender: ExtensionButton) {
        open(sender.manifest, from: sender)
    }

    /// The popup if it has one, else its options page.
    private func open(_ manifest: ExtensionManifest, from anchor: NSView) {
        if manifest.popupURL != nil {
            onPopup?(manifest, anchor)
        } else if let url = manifest.optionsURL {
            onOpen?(url)
        } else if let button = anchor as? NSButton, let menu = button.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
        }
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // Items keep the enabled state set here: one with neither a popup nor
        // an options page has nothing to open.
        menu.autoenablesItems = false
        for manifest in ExtensionStore.shared.running {
            let item = MenuActionItem(title: manifest.name) { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.open(manifest, from: sender)
            }
            item.image = manifest.image(size: 16)
            item.isEnabled = manifest.popupURL != nil || manifest.optionsURL != nil
            if let url = manifest.optionsURL, manifest.popupURL != nil {
                // Holding Option shows Options instead.
                menu.addItem(item)
                let options = MenuActionItem(title: "\(manifest.name) Options") { [weak self] in self?.onOpen?(url) }
                options.image = item.image
                options.keyEquivalentModifierMask = .option
                options.isAlternate = true
                menu.addItem(options)
            } else {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Manage Extensions…", action: #selector(AppDelegate.manageExtensions(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    private func contextMenu(for manifest: ExtensionManifest) -> NSMenu {
        let menu = NSMenu()
        if let url = manifest.optionsURL {
            menu.addItem(MenuActionItem(title: "Options") { [weak self] in self?.onOpen?(url) })
        }
        menu.addItem(MenuActionItem(title: "Unpin") {
            let store = ExtensionStore.shared
            if let index = store.entries.firstIndex(where: { $0.path == manifest.folder }) {
                store.setPinned(false, at: index)
            }
        })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Manage Extensions…", action: #selector(AppDelegate.manageExtensions(_:)), keyEquivalent: "")
        return menu
    }
}

/// A pinned extension's toolbar button.
private final class ExtensionButton: NSButton {
    let manifest: ExtensionManifest

    init(manifest: ExtensionManifest) {
        self.manifest = manifest
        super.init(frame: .zero)
        image = manifest.image(size: 16)
        toolTip = manifest.actionTitle ?? manifest.name
        bezelStyle = .toolbar
        setAccessibilityLabel(manifest.name)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An extension's popup page in a popover, sized to the page the way Chrome
/// sizes popups, from 25×25 up to 800×600 points.
@MainActor
final class ExtensionPopover: NSObject, NSPopoverDelegate, TabDelegate {
    /// The popup opened a link in a new tab.
    var onOpenTab: ((String, Bool) -> Void)?
    /// The popup is gone, browser and all.
    var onClose: (() -> Void)?
    /// A Command or Control key press before the popup's page sees it. True
    /// if a menu took it.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    let manifest: ExtensionManifest
    private let popover = NSPopover()
    private let tab: Tab
    private var closing = false

    /// The popup runs in `profile`'s request context, like its tabs.
    init(manifest: ExtensionManifest, profile: ProfileContext) {
        self.manifest = manifest
        tab = Tab(profile: profile)
        super.init()
    }

    func show(relativeTo anchor: NSView) {
        guard let url = manifest.popupURL else { return }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = container.frame.size
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // The browser needs its view in a window, so it starts once shown.
        tab.hostView.frame = container.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        container.addSubview(tab.hostView)
        tab.delegate = self
        tab.start(url: url)
        tab.autoResize(min: NSSize(width: 25, height: 25), max: NSSize(width: 800, height: 600))
        tab.focus()
    }

    func close() {
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        tab.close()
    }

    // MARK: TabDelegate

    func tab(_ tab: Tab, autoResizedTo size: NSSize) {
        popover.contentSize = NSSize(width: max(size.width, 25), height: max(size.height, 25))
    }

    func tab(_ tab: Tab, openInNewTab url: String, background: Bool) {
        onOpenTab?(url, background)
    }

    /// The popover closed, or the page called window.close().
    func tabReadyToClose(_ tab: Tab) {
        closing = true
        tab.detach()
        tab.hostView.removeFromSuperview()
        popover.close()
        onClose?()
    }

    func tabDidChange(_ tab: Tab) {}
    func tabProgressChanged(_ tab: Tab) {}
    func tab(_ tab: Tab, foundMatches count: Int, active: Int, final: Bool) {}
    /// Cmd+W closes the popup. Other shortcuts go to the menus first, as they
    /// do from a tab.
    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return onKeyEquivalent?(event) ?? false
    }
}
