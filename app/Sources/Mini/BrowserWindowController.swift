import AppKit
import CMiniCore

/// One window, one CEF browser, and a toolbar with back, forward, reload and
/// the address field.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?

    private let browserView = BrowserHostView()
    private let addressField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private var browserID: Int32 = -1
    private var isLoading = false

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
        window.contentView = browserView
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MiniToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if !window.setFrameUsingName("MiniBrowserWindow") { window.center() }

        configureControls()
        createBrowser(url: url)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Browser

    private func createBrowser(url: String) {
        window?.layoutIfNeeded()
        let size = browserView.bounds.size
        let callbacks = MiniBrowserCallbacks(
            ctx: Unmanaged.passUnretained(self).toOpaque(),
            address_changed: { ctx, url in
                guard let ctx, let url else { return }
                BrowserWindowController.from(ctx).addressChanged(String(cString: url))
            },
            title_changed: { ctx, title in
                guard let ctx, let title else { return }
                BrowserWindowController.from(ctx).titleChanged(String(cString: title))
            },
            loading_state_changed: { ctx, loading, back, forward in
                guard let ctx else { return }
                BrowserWindowController.from(ctx).loadingStateChanged(loading: loading, back: back, forward: forward)
            }
        )
        let view = Unmanaged.passUnretained(browserView).toOpaque()
        browserID = mini_browser_create(view, Int32(size.width), Int32(size.height), url, callbacks)
        addressField.stringValue = url
    }

    /// CEF calls back on the main thread, so hopping onto the main actor is safe.
    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> BrowserWindowController {
        Unmanaged<BrowserWindowController>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func addressChanged(_ url: String) {
        MainActor.assumeIsolated {
            // Don't overwrite what the user is typing.
            if addressField.currentEditor() == nil { addressField.stringValue = url }
        }
    }

    nonisolated private func titleChanged(_ title: String) {
        MainActor.assumeIsolated { window?.title = title.isEmpty ? "Mini" : title }
    }

    nonisolated private func loadingStateChanged(loading: Bool, back: Bool, forward: Bool) {
        MainActor.assumeIsolated {
            isLoading = loading
            backButton.isEnabled = back
            forwardButton.isEnabled = forward
            reloadButton.image = symbol(loading ? "xmark" : "arrow.clockwise")
            reloadButton.toolTip = loading ? "Stop" : "Reload"
        }
    }

    // MARK: Actions (also reached from the menu through the responder chain)

    @objc func goBack(_ sender: Any?) { mini_browser_go_back(browserID) }
    @objc func goForward(_ sender: Any?) { mini_browser_go_forward(browserID) }

    @objc func reloadOrStop(_ sender: Any?) {
        isLoading ? mini_browser_stop(browserID) : mini_browser_reload(browserID)
    }

    @objc func reloadPage(_ sender: Any?) { mini_browser_reload(browserID) }

    @objc func openLocation(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressEntered(_ sender: NSTextField) {
        let input = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let url = AddressInput.url(for: input)
        sender.stringValue = url
        mini_browser_load_url(browserID, url)
        window?.makeFirstResponder(browserView)
        mini_browser_set_focus(browserID, true)
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mini_browser_try_close(browserID)
    }

    func windowWillClose(_ notification: Notification) {
        mini_browser_detach(browserID)
        // Releasing CEF's view lets CEF finish closing the browser. The last
        // browser to close ends the message loop and the app quits.
        browserView.subviews.forEach { $0.removeFromSuperview() }
        onClose?()
    }

    // MARK: Toolbar

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let reload = NSToolbarItem.Identifier("reload")
        static let address = NSToolbarItem.Identifier("address")
    }

    private func configureControls() {
        for (button, name, tip, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack(_:))),
            (forwardButton, "chevron.right", "Forward", #selector(goForward(_:))),
            (reloadButton, "arrow.clockwise", "Reload", #selector(reloadOrStop(_:))),
        ] {
            button.image = symbol(name)
            button.toolTip = tip
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        addressField.placeholderString = "Search or enter website"
        addressField.bezelStyle = .roundedBezel
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered(_:))
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.reload, .flexibleSpace, Item.address, .flexibleSpace]
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
        case Item.address:
            item.view = addressField
            item.label = "Address"
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            addressField.widthAnchor.constraint(lessThanOrEqualToConstant: 720).isActive = true
            let preferred = addressField.widthAnchor.constraint(equalToConstant: 720)
            preferred.priority = .defaultLow
            preferred.isActive = true
        default: return nil
        }
        return item
    }
}

/// Hosts CEF's view and keeps it the size of the window content.
final class BrowserHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}

/// Turns address bar input into a URL: a URL if it looks like one, else a search.
enum AddressInput {
    static func url(for input: String) -> String {
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return input
        }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let looksLikeHost = !input.contains(" ")
            && (host.contains(".") || host.hasPrefix("localhost") || host.contains(":"))
        if looksLikeHost {
            let scheme = host.hasPrefix("localhost") || host.hasPrefix("127.") ? "http" : "https"
            return "\(scheme)://\(input)"
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url!.absoluteString
    }
}
