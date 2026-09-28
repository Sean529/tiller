import AppKit

/// The menu bar, built in code so the app needs no xib and no ibtool.
enum MainMenu {
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
        file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        add(view, titled: "View", to: main)

        let history = NSMenu(title: "History")
        history.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        add(history, titled: "History", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    @MainActor
    private static func add(_ submenu: NSMenu, titled title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}
