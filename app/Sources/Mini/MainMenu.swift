import AppKit

/// The menu bar, built in code so the app needs no xib and no ibtool.
enum MainMenu {
    /// Shortcuts from this menu go to the page first. See `Tab`'s key handling.
    static let editTitle = "Edit"

    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mini", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mini", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Mini", to: main)

        // Browser actions have no target, so they go to the key window's
        // BrowserWindowController through the responder chain.
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: editTitle)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: editTitle, to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Show Agent", action: #selector(BrowserWindowController.toggleAgentPanel(_:)), keyEquivalent: "A")
        add(view, titled: "View", to: main)

        let history = NSMenu(title: "History")
        history.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        add(history, titled: "History", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)), keyEquivalent: "{")
        window.addItem(withTitle: "Show Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "}")
        // Ctrl+Tab and Ctrl+Shift+Tab, and Cmd+1 to Cmd+9, work but stay out of sight.
        hidden(window, "Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", [.control])
        hidden(window, "Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        for number in 1...9 {
            let item = hidden(window, "Select Tab \(number)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(number)", [.command])
            item.tag = number
        }
        window.addItem(.separator())
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    @MainActor
    @discardableResult
    private static func hidden(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    @MainActor
    private static func add(_ submenu: NSMenu, titled title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}
