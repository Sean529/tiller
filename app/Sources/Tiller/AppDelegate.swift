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
        // `-importChrome YES` imports everything from Chrome's last-used
        // profile and logs the result.
        if UserDefaults.standard.bool(forKey: "importChrome") {
            Task {
                do {
                    let (profiles, lastUsed) = try ChromeReader.profiles()
                    guard let profile = profiles.first(where: { $0.directory == lastUsed }) ?? profiles.first else { return }
                    for result in await ChromeImporter.run(profile: profile, kinds: Set(ImportKind.allCases)) {
                        NSLog("Tiller import: %@: %@", result.title, result.error?.localizedDescription ?? result.detail)
                    }
                } catch {
                    NSLog("Tiller import: %@", error.localizedDescription)
                }
            }
        }
        #endif
    }

    /// Cmd+Q, the Dock or logging out, before the tabs start closing.
    fileprivate func quitRequested() {
        windowController?.freezeSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
