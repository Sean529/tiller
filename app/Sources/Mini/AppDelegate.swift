import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private let controlServer = ControlServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let url = UserDefaults.standard.string(forKey: "url") ?? "https://www.google.com/"
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self] in self?.windowController = nil }
        controller.showWindow(nil)
        windowController = controller
        controlServer.browser = controller
        if !controlServer.start() {
            NSLog("Mini: control socket unavailable, agent tools will not work")
        }
        NSApp.activate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
