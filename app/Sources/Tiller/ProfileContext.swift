import AppKit
import CTillerCore

/// An open profile: its stores, its Chromium request context, its control
/// socket, its scheduled prompts and its window. One Tiller process runs
/// every open profile, each in a window of its own, under one Dock icon.
/// A profile opens with `open(_:urls:)` and closes with its window.
@MainActor
final class ProfileContext {
    /// The open profiles, in the order they opened.
    private(set) static var all: [ProfileContext] = []

    /// Set from a quit until Tiller exits, so the profiles closing with it
    /// stay on the list the next launch opens.
    static var isQuitting = false

    static func opened(_ id: String) -> ProfileContext? {
        all.first { $0.id == id }
    }

    /// The profile whose browser or Settings window is in front, else the
    /// one used last that is open, else any open one. For menus and links
    /// that aren't about a particular window.
    static var active: ProfileContext? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let profile = all.first(where: { $0.owns(window) }) { return profile }
            if let settings = (window.sheetParent ?? window).windowController as? SettingsWindowController,
                let profile = opened(settings.profileID) {
                return profile
            }
        }
        return opened(Profiles.lastUsed.id) ?? all.first
    }

    let id: String
    /// `Profiles/<id>` in the root folder.
    let folder: String
    let settings: ProfileSettings
    let session: SessionStore
    let history: HistoryStore
    let passwords: PasswordStore
    let agentHistory: AgentHistoryStore
    let providers: AgentProviderStore
    let skills: AgentSkillStore
    let schedules: AgentScheduleStore
    private(set) lazy var scheduler = AgentScheduler(profile: self)
    /// The control socket tiller_mcp connects to for this profile. Agents
    /// are given it in TILLER_SOCKET.
    let socketPath: String
    private lazy var control = ControlServer(profile: self)
    /// The Chromium request context this profile's tabs run in, or -1 until
    /// it is created.
    private(set) var context: Int32 = -1
    private(set) var window: BrowserWindowController?
    /// Holds the profile's `instance.lock` while it is open.
    private let lock: Int32
    /// Links to open once the window is up.
    private var pendingURLs: [String] = []

    var name: String { Profiles.name(of: id) }

    /// A file in the profile's folder.
    func file(_ name: String) -> String { folder + "/" + name }

    private init(id: String, lock: Int32, socketPath: String) {
        self.id = id
        self.lock = lock
        self.socketPath = socketPath
        folder = Profiles.folder(for: id)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        settings = ProfileSettings(profileID: id)
        session = SessionStore(folder: folder)
        history = HistoryStore(path: folder + "/history.sqlite")
        passwords = PasswordStore(profileID: id, folder: folder)
        agentHistory = AgentHistoryStore(folder: folder)
        providers = AgentProviderStore(settings: settings)
        skills = AgentSkillStore(folder: folder, settings: settings)
        schedules = AgentScheduleStore(folder: folder)
    }

    private func owns(_ window: NSWindow) -> Bool {
        guard let controller = self.window else { return false }
        return window === controller.window || window.sheetParent === controller.window
            || controller.ownsChild(window)
    }

    // MARK: Opening

    /// Brings the profile's window forward with `urls` in new tabs, or opens
    /// the profile: its window gets the tabs of last time, or the homepage,
    /// then `urls`.
    static func open(_ id: String, urls: [String] = []) {
        if let profile = opened(id) {
            profile.show(urls: urls)
            return
        }
        guard Profiles.profile(id) != nil else { return }
        let lock: Int32
        switch Profiles.claim(id) {
        case .success(let fd): lock = fd
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't open the profile"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        // TILLER_SOCKET stands in for the first profile's socket, for data
        // folders whose path is too long for one.
        let override = ProcessInfo.processInfo.environment["TILLER_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        let socket = all.isEmpty ? override : nil
        let profile = ProfileContext(id: id, lock: lock, socketPath: socket ?? Profiles.socketPath(for: id))
        profile.pendingURLs = urls
        all.append(profile)
        profile.createContext()
        Profiles.setOpen(all.map(\.id))
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// The profile's Chromium request context. Browsers can only be created
    /// in it once Chromium says it is ready, which then opens the window.
    private func createContext() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        context = tiller_context_create(Profiles.cachePath(for: id), ctx) { ctx in
            guard let ctx else { return }
            let profile = Unmanaged<ProfileContext>.fromOpaque(ctx).takeRetainedValue()
            MainActor.assumeIsolated { profile.contextReady() }
        }
        if context < 0 {
            Unmanaged<ProfileContext>.fromOpaque(ctx).release()
            NSLog("Tiller: could not create the request context for profile %@", id)
            close()
        }
    }

    private func contextReady() {
        guard window == nil, Self.opened(id) === self else { return }
        // Last time's tabs, unless they were all blank. Links come after them.
        let restore = settings.launchTabs == .restore && session.openTabs.contains { !$0.isBlank }
        let restored = restore ? session.openTabs : []
        var urls = pendingURLs
        pendingURLs = []
        if urls.isEmpty && restored.isEmpty { urls = [settings.homepageURL] }
        let controller = BrowserWindowController(
            profile: self, restoring: restored, selected: session.selectedIndex, opening: urls.first
        )
        for url in urls.dropFirst() { controller.openInNewTab(url) }
        controller.onClose = { [weak self] in self?.close() }
        window = controller
        controller.showProfile(name: Profiles.all.count > 1 ? name : nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !control.start() {
            NSLog("Tiller: control socket for profile %@ unavailable, agent tools will not work", id)
        }
        scheduler.start()
        NSApp.activate()
        NotificationCenter.default.post(name: .profileDidOpen, object: self)
    }

    /// Brings the window forward and opens `urls` in it.
    func show(urls: [String] = []) {
        guard let window else {
            pendingURLs += urls
            return
        }
        for url in urls { window.openInNewTab(url) }
        if window.window?.isMiniaturized == true { window.window?.deminiaturize(nil) }
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Closing

    /// Called once the window has closed: the stores write what's pending,
    /// and the socket, schedules and lock go. Closing the last profile quits
    /// Tiller, since the core's message loop ends with the last browser.
    private func close() {
        guard let index = Self.all.firstIndex(where: { $0 === self }) else { return }
        Self.all.remove(at: index)
        window = nil
        session.flush()
        agentHistory.flush()
        agentHistory.waitForWrites()
        control.stop()
        scheduler.stop()
        if context >= 0 { tiller_context_release(context) }
        Profiles.release(lock)
        // The last profile to close is the one the next launch opens, as
        // are all of them when Tiller quits.
        if !Self.isQuitting && !Self.all.isEmpty {
            Profiles.setOpen(Self.all.map(\.id))
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted with the profile once its window is up.
    static let profileDidOpen = Notification.Name("TillerProfileDidOpen")
}
