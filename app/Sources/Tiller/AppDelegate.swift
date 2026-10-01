import AppKit
import CTillerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private let controlServer = ControlServer()
    private var settingsController: SettingsWindowController?
    /// Links that arrived before the window, which opens them.
    private var pendingURLs: [URL] = []

    @objc func showSettings(_ sender: Any?) {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        controller.showWindow(sender)
    }

    #if DEBUG
    /// Opens Settings on the pane titled `pane`, for `ui.settings` on the control socket.
    func showSettings(pane: String) {
        showSettings(nil)
        settingsController?.showPane(titled: pane)
    }
    #endif

    /// The manual, in a new tab.
    @objc func openHelp(_ sender: Any?) {
        openInNewTab("https://github.com/sorrycc/tiller/tree/master/docs")
    }

    @objc func openGitHub(_ sender: Any?) {
        openInNewTab("https://github.com/sorrycc/tiller")
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        Task { await CommandLineTool.installAndReport() }
    }

    /// A profile in the Profiles menu. Its id is the item's represented object.
    @objc func openProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Profiles.open(id)
    }

    @objc func newProfile(_ sender: Any?) {
        ProfileNamePrompt.run("New Profile", button: "Create", on: nil) { name in
            Profiles.open(try Profiles.create(named: name).id)
        }
    }

    @objc func manageProfiles(_ sender: Any?) {
        showSettings(sender)
        settingsController?.showPane(titled: ProfilesSettingsPane.paneTitle)
    }

    /// The Agent pane, from an error about the agent's command.
    func showAgentSettings() {
        showSettings(nil)
        settingsController?.showPane(titled: "Agent")
    }

    @objc func manageExtensions(_ sender: Any?) {
        showSettings(sender)
        settingsController?.showPane(titled: ExtensionsSettingsPane.paneTitle)
    }

    /// Opens `url` in a new tab of the browser window, for Settings and links
    /// in the agent panel.
    func openInNewTab(_ url: String, background: Bool = false) {
        windowController?.openInNewTab(url, background: background)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tiller has tabs of its own. This keeps the system's Show Tab Bar and
        // Show All Tabs out of the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()

        tiller_core_set_quit_handler {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.quitRequested() }
        }

        // Last time's tabs, unless they were all blank. `-url` and links from
        // other apps open after them.
        let session = SessionStore.shared
        let restore = Settings.launchTabs == .restore && session.openTabs.contains { !$0.isBlank }
        let restored = restore ? session.openTabs : []
        // `-openURLs`, one per line, carries links another profile's Tiller passed on.
        var urls = (UserDefaults.standard.string(forKey: "openURLs") ?? "").split(separator: "\n").map(String.init)
        urls += pendingURLs.map(\.absoluteString)
        pendingURLs = []
        if let url = UserDefaults.standard.string(forKey: "url") { urls.insert(url, at: 0) }
        if urls.isEmpty && restored.isEmpty { urls = [Settings.homepageURL] }
        let controller = BrowserWindowController(restoring: restored, selected: session.selectedIndex, opening: urls.first)
        for url in urls.dropFirst() { controller.openInNewTab(url) }
        controller.onClose = { [weak self] in self?.windowController = nil }
        controller.showWindow(nil)
        windowController = controller
        NotificationCenter.default.addObserver(
            self, selector: #selector(profilesChanged(_:)), name: .profilesDidChange, object: nil
        )
        showProfile()
        DownloadStore.shared.start()
        controlServer.browser = controller
        if !controlServer.start() {
            NSLog("Tiller: control socket unavailable, agent tools will not work")
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak controller] in
            MainActor.assumeIsolated { DefaultBrowser.askOnce(on: controller?.window) }
        }
        #if DEBUG
        if let prompt = UserDefaults.standard.string(forKey: "agentPrompt") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak controller] in
                MainActor.assumeIsolated { controller?.sendAgentPrompt(prompt) }
            }
        }
        // `-addExtension <path>` adds an unpacked folder or a CRX file and
        // logs the result. It loads at the next launch.
        if let path = UserDefaults.standard.string(forKey: "addExtension") {
            Task {
                do {
                    let manifest = path.hasSuffix(".crx")
                        ? try await ExtensionStore.shared.addCRX(path) : try ExtensionStore.shared.addFolder(path)
                    NSLog("Tiller extension: added %@ (%@)", manifest.name, manifest.id)
                } catch {
                    NSLog("Tiller extension: %@", error.localizedDescription)
                }
            }
        }
        // `-importChrome YES` imports everything from Chrome's last-used
        // profile and logs the result. `-importChrome extensions,history`
        // imports only those.
        if let value = UserDefaults.standard.string(forKey: "importChrome"), value != "NO" {
            let names = Set(value.split(separator: ",").map(String.init))
            let kinds = value == "YES"
                ? Set(ImportKind.allCases) : Set(ImportKind.allCases.filter { names.contains("\($0)") })
            Task {
                do {
                    let (profiles, lastUsed) = try ChromeReader.profiles()
                    guard let profile = profiles.first(where: { $0.directory == lastUsed }) ?? profiles.first else { return }
                    for result in await ChromeImporter.run(profile: profile, kinds: kinds) {
                        NSLog("Tiller import: %@: %@", result.title, result.error?.localizedDescription ?? result.detail)
                    }
                } catch {
                    NSLog("Tiller import: %@", error.localizedDescription)
                }
            }
        }
        #endif
    }

    /// Web links and HTML files from other apps, with Tiller as the default
    /// browser or chosen in Open With. Links that start Tiller open in it: a
    /// plain launch picks the profile used last already, and a profile started
    /// to open links must not pass them back.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard windowController != nil else {
            pendingURLs += urls
            return
        }
        IncomingLinks.route(urls) { [weak self] urls in
            guard let windowController = self?.windowController else { return }
            for url in urls { windowController.openInNewTab(url.absoluteString) }
            NSApp.activate()
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        IncomingLinks.willBecomeActive()
    }

    /// Another Tiller may have added, renamed or removed profiles meanwhile.
    func applicationDidBecomeActive(_ notification: Notification) {
        Profiles.markUsed()
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    @objc private func profilesChanged(_ notification: Notification) {
        showProfile()
    }

    /// With more than one profile, each Tiller names its own in the Dock badge
    /// and the toolbar, since every one has the same icon.
    private func showProfile() {
        let name = Profiles.all.count > 1 ? Profiles.currentName : nil
        NSApp.dockTile.badgeLabel = name
        windowController?.showProfile(name: name)
    }

    /// Cmd+Q, the Dock or logging out. Closes every tab, which closes the
    /// window, and the core quits when the last browser is gone. The core
    /// closes only tabs that have a browser, so this can't be left to it:
    /// a restored tab that hasn't loaded yet would be selected, start, and
    /// keep Tiller running.
    fileprivate func quitRequested() {
        windowController?.closeAllTabs()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
