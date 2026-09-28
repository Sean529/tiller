import AppKit

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

        let url = UserDefaults.standard.string(forKey: "url") ?? Settings.homepageURL
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self] in self?.windowController = nil }
        controller.showWindow(nil)
        windowController = controller
        controlServer.browser = controller
        if !controlServer.start() {
            NSLog("Mini: control socket unavailable, agent tools will not work")
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
                        NSLog("Mini import: %@: %@", result.title, result.error?.localizedDescription ?? result.detail)
                    }
                } catch {
                    NSLog("Mini import: %@", error.localizedDescription)
                }
            }
        }
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
