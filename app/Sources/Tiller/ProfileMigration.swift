import AppKit

/// Brings over what Tiller kept before it had profiles: the data straight in
/// the root folder moves to `Profiles/default`, and the app's settings move to
/// that profile's user defaults. Runs after RenameMigration and before the
/// core starts, because Chromium opens the profile's folder as soon as it loads.
enum ProfileMigration {
    /// Settings that belong to a profile. Window frames and debug launch
    /// arguments stay with the app.
    private static let keys: Set<String> = [
        "homepage", "launchTabs", "newTabPage", "searchEngine", "searchTemplate",
        "agent", "agentFolder", "agentInstructions", "agentPanelVisible", "agentShortcut", "agentTabs",
    ]
    private static let keyPrefixes = ["agentTool.", "agentPath."]

    static func run() {
        moveData()
        moveSettings()
    }

    /// Moves everything in the root folder into the default profile's folder,
    /// once, while there is no `Profiles` folder yet.
    private static func moveData() {
        let manager = FileManager.default
        let root = Profiles.root
        let target = Profiles.folder(for: Profiles.defaultID)
        guard !manager.fileExists(atPath: root + "/Profiles"),
              let items = try? manager.contentsOfDirectory(atPath: root), !items.isEmpty else { return }
        // A Tiller from before profiles would still be using these files.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            // NSApp can't exist yet, so this alert comes from CoreFoundation.
            CFUserNotificationDisplayAlert(
                0, kCFUserNotificationCautionAlertLevel, nil, nil, nil,
                "Quit Tiller first" as CFString,
                "This Tiller keeps each profile in its own folder. Quit the Tiller that is running, then open this one again to move your tabs, history, passwords and chats into the first profile." as CFString,
                "Quit" as CFString, nil, nil, nil)
            exit(0)
        }
        do {
            try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
        } catch {
            NSLog("Tiller: could not create %@: %@", target, error.localizedDescription)
            return
        }
        for item in items where !["Profiles", "profiles.json", "profiles.lock"].contains(item) {
            let source = root + "/" + item
            // Left from the last run. The profile's own socket goes in its folder.
            if item == "control.sock" {
                try? manager.removeItem(atPath: source)
                continue
            }
            do {
                try manager.moveItem(atPath: source, toPath: target + "/" + item)
            } catch {
                NSLog("Tiller: could not move %@: %@", source, error.localizedDescription)
            }
        }
        RenameMigration.repointChats(in: target, from: root, to: target)
    }

    /// Moves profile settings from the app's defaults to the default profile's,
    /// unless that profile has settings already.
    private static func moveSettings() {
        let standard = UserDefaults.standard
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = standard.persistentDomain(forName: bundleID) else { return }
        let settings = domain.filter { key, _ in keys.contains(key) || keyPrefixes.contains { key.hasPrefix($0) } }
        guard !settings.isEmpty else { return }
        let suite = Profiles.suiteName(for: Profiles.defaultID)
        if standard.persistentDomain(forName: suite)?.isEmpty ?? true {
            standard.setPersistentDomain(settings, forName: suite)
        }
        for key in settings.keys {
            standard.removeObject(forKey: key)
        }
    }
}
