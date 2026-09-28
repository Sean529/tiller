import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let url = UserDefaults.standard.string(forKey: "url") ?? "https://www.google.com/"
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self] in self?.windowController = nil }
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
