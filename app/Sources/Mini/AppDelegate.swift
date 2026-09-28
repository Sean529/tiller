import AppKit
import CMiniCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let cefLoaded = mini_core_load_cef()
        let version = String(cString: mini_core_version())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini"
        window.titlebarAppearsTransparent = true
        window.contentView = PlaceholderView(
            lines: [version, cefLoaded ? "CEF framework loaded" : "CEF framework NOT loaded"]
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Stands in for the browser view until step 4 embeds CEF.
final class PlaceholderView: NSView {
    init(lines: [String]) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: lines.joined(separator: "\n"))
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
