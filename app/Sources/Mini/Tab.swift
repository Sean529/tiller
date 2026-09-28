import AppKit
import CMiniCore

@MainActor
protocol TabDelegate: AnyObject {
    /// Title, URL, loading state or favicon changed.
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, openInNewTab url: String, background: Bool)
    /// beforeunload passed. The delegate removes the tab, which finishes the close.
    func tabReadyToClose(_ tab: Tab)
    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool
}

/// One CEF browser and the view that hosts it.
@MainActor
final class Tab {
    weak var delegate: TabDelegate?
    let hostView = BrowserHostView()

    private(set) var browserID: Int32 = -1
    private(set) var url = ""
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var favicon: NSImage?

    /// The URL and title last written to history, so each change is saved once.
    var recordedVisit: (url: String, title: String)?

    var isBlank: Bool { url.isEmpty || url == "about:blank" }

    var displayTitle: String {
        if !title.isEmpty && title != url { return title }
        if isBlank { return "New Tab" }
        return URL(string: url)?.host() ?? url
    }

    /// Creates the browser inside `hostView`, which must already be in a window
    /// and sized.
    func start(url: String) {
        self.url = url
        let size = hostView.bounds.size
        let callbacks = MiniBrowserCallbacks(
            ctx: Unmanaged.passUnretained(self).toOpaque(),
            address_changed: { ctx, url in
                guard let ctx, let url else { return }
                Tab.from(ctx).addressChanged(String(cString: url))
            },
            title_changed: { ctx, title in
                guard let ctx, let title else { return }
                Tab.from(ctx).titleChanged(String(cString: title))
            },
            loading_state_changed: { ctx, loading, back, forward in
                guard let ctx else { return }
                Tab.from(ctx).loadingStateChanged(loading: loading, back: back, forward: forward)
            },
            favicon_changed: { ctx, png, len in
                guard let ctx else { return }
                let data = png.map { Data(bytes: $0, count: len) } ?? Data()
                Tab.from(ctx).faviconChanged(data)
            },
            open_tab: { ctx, url, background in
                guard let ctx, let url else { return }
                Tab.from(ctx).openTab(String(cString: url), background: background)
            },
            close_ready: { ctx in
                guard let ctx else { return }
                Tab.from(ctx).closeReady()
            },
            key_equivalent: { ctx, event in
                guard let ctx, let event else { return false }
                return Tab.from(ctx).keyEquivalent(UInt(bitPattern: event))
            }
        )
        let view = Unmanaged.passUnretained(hostView).toOpaque()
        browserID = mini_browser_create(view, Int32(size.width), Int32(size.height), url, callbacks)
    }

    // MARK: Commands

    func load(_ url: String) {
        self.url = url
        mini_browser_load_url(browserID, url)
    }

    func goBack() { mini_browser_go_back(browserID) }
    func goForward() { mini_browser_go_forward(browserID) }
    func reload() { mini_browser_reload(browserID) }
    func stop() { mini_browser_stop(browserID) }

    /// Runs `code` in the main frame. Does nothing once the tab has closed.
    func executeJavaScript(_ code: String) { mini_browser_execute_js(browserID, code) }

    func focus() {
        hostView.window?.makeFirstResponder(hostView)
        mini_browser_set_focus(browserID, true)
    }

    /// Runs beforeunload, then calls `tabReadyToClose` unless the page cancels.
    func close() {
        if browserID < 0 {
            delegate?.tabReadyToClose(self)
        } else {
            mini_browser_close(browserID)
        }
    }

    /// Stops callbacks. Call before the tab is released.
    func detach() {
        if browserID >= 0 { mini_browser_detach(browserID) }
    }

    // MARK: Callbacks from CEF, always on the main thread

    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> Tab {
        Unmanaged<Tab>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func addressChanged(_ url: String) {
        MainActor.assumeIsolated {
            self.url = url
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func titleChanged(_ title: String) {
        MainActor.assumeIsolated {
            self.title = title
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func loadingStateChanged(loading: Bool, back: Bool, forward: Bool) {
        MainActor.assumeIsolated {
            isLoading = loading
            canGoBack = back
            canGoForward = forward
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func faviconChanged(_ png: Data) {
        MainActor.assumeIsolated {
            favicon = png.isEmpty ? nil : NSImage(data: png)
            favicon?.size = NSSize(width: 16, height: 16)
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func openTab(_ url: String, background: Bool) {
        MainActor.assumeIsolated { delegate?.tab(self, openInNewTab: url, background: background) }
    }

    nonisolated private func closeReady() {
        // CEF is inside its close sequence here. Remove the view on the next
        // turn of the run loop rather than from inside the callback.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { delegate?.tabReadyToClose(self) }
        }
    }

    /// `event` is the NSEvent's address, which crosses into the main actor as a
    /// plain integer because raw pointers aren't Sendable.
    nonisolated private func keyEquivalent(_ event: UInt) -> Bool {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: event) else { return false }
            let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
            return delegate?.tab(self, performKeyEquivalent: event) ?? false
        }
    }
}

/// Hosts CEF's view and keeps it the size of the tab area.
final class BrowserHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}
