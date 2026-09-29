import AppKit
import CTillerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private let controlServer = ControlServer()
    private var settingsController: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        controller.showWindow(sender)
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

    @objc func manageExtensions(_ sender: Any?) {
        showSettings(sender)
        settingsController?.showPane(titled: ExtensionsSettingsPane.paneTitle)
    }

    /// Opens `url` in a new tab of the browser window, for Settings.
    func openInNewTab(_ url: String) {
        windowController?.openInNewTab(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        tiller_core_set_quit_handler {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.quitRequested() }
        }

        // Last time's tabs, unless they were all blank. `-url` opens after them.
        let session = SessionStore.shared
        let restore = Settings.launchTabs == .restore && session.openTabs.contains { !$0.isBlank }
        let restored = restore ? session.openTabs : []
        let url = UserDefaults.standard.string(forKey: "url") ?? (restored.isEmpty ? Settings.homepageURL : nil)
        let controller = BrowserWindowController(restoring: restored, selected: session.selectedIndex, opening: url)
        controller.onClose = { [weak self] in self?.windowController = nil }
        controller.showWindow(nil)
        windowController = controller
        NotificationCenter.default.addObserver(
            self, selector: #selector(profilesChanged(_:)), name: .profilesDidChange, object: nil
        )
        showProfile()
        controlServer.browser = controller
        if !controlServer.start() {
            NSLog("Tiller: control socket unavailable, agent tools will not work")
        }
        NSApp.activate()
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

    /// Cmd+Q, the Dock or logging out, before the tabs start closing.
    fileprivate func quitRequested() {
        windowController?.freezeSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
