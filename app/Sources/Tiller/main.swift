import AppKit
import CTillerCore

RenameMigration.run()

// tiller_core_start installs the NSApplication subclass CEF needs, so it has to
// run before anything touches NSApp.
let code = tiller_core_start()
if code != 0 { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// CEF runs [NSApp run] and returns after the last browser closes.
tiller_core_run()
