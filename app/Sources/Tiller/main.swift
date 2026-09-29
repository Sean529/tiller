import AppKit
import CTillerCore

RenameMigration.run()
ProfileMigration.run()

// One process per profile. When this profile is open already, bring that
// process forward instead.
if let running = Profiles.claim() {
    NSRunningApplication(processIdentifier: running)?.activate()
    exit(0)
}

// tiller_core_start installs the NSApplication subclass CEF needs, so it has to
// run before anything touches NSApp. Chromium only loads extensions at startup.
let code = tiller_core_start(DataDirectory.path, ExtensionStore.shared.launchArgument)
if code != 0 { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// CEF runs [NSApp run] and returns after the last browser closes.
tiller_core_run()
