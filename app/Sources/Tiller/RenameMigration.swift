import AppKit

/// Brings over what the app kept while it was called Mini: its data folder,
/// its settings and its command-line link. The password key is copied when
/// first needed, in `PasswordKey`. Runs before the core starts, because
/// Chromium opens the profile in the data folder as soon as it loads.
enum RenameMigration {
    private static let oldBundleID = "dev.sorrycc.mini"
    private static let oldDataDirectory = NSHomeDirectory() + "/Library/Application Support/Mini"

    static func run() {
        moveDataDirectory()
        copySettings()
        removeOldCommandLink()
    }

    /// Moves the folder, unless TILLER_DATA_DIR picks another one or Tiller
    /// already has its own. Mini must not be running, since moving a profile
    /// Chromium has open would break both apps.
    private static func moveDataDirectory() {
        let manager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        guard environment["TILLER_DATA_DIR"]?.isEmpty ?? true,
              manager.fileExists(atPath: oldDataDirectory),
              !manager.fileExists(atPath: Profiles.root) else { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).isEmpty {
            // NSApp can't exist yet, so this alert comes from CoreFoundation.
            CFUserNotificationDisplayAlert(
                0, kCFUserNotificationCautionAlertLevel, nil, nil, nil,
                "Quit Mini first" as CFString,
                "Tiller is the new name of Mini. Quit Mini, then open Tiller again to bring over your tabs, history, passwords and settings." as CFString,
                "Quit" as CFString, nil, nil, nil)
            exit(0)
        }
        do {
            try manager.moveItem(atPath: oldDataDirectory, toPath: Profiles.root)
        } catch {
            NSLog("Tiller: could not move %@: %@", oldDataDirectory, error.localizedDescription)
            return
        }
        repointChats(in: Profiles.root, from: oldDataDirectory, to: Profiles.root)
    }

    /// Saved chats in the data folder `dataDirectory` record the folder their
    /// agent ran in, which was inside the data folder unless Settings chose
    /// another. Those inside `old` move to the same place inside `new`.
    static func repointChats(in dataDirectory: String, from old: String, to new: String) {
        let url = URL(fileURLWithPath: dataDirectory + "/agent-chats/index.json")
        guard let data = try? Data(contentsOf: url),
              var index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var conversations = index["conversations"] as? [[String: Any]] else { return }
        for i in conversations.indices {
            guard let directory = conversations[i]["directory"] as? String,
                  directory == old || directory.hasPrefix(old + "/") else { continue }
            conversations[i]["directory"] = new + directory.dropFirst(old.count)
        }
        index["conversations"] = conversations
        if let updated = try? JSONSerialization.data(withJSONObject: index) {
            try? updated.write(to: url, options: .atomic)
        }
    }

    /// Copies Mini's user defaults while Tiller has none. Window and split
    /// view autosave keys carry the app's name, so they are renamed too.
    private static func copySettings() {
        let defaults = UserDefaults.standard
        guard let bundleID = Bundle.main.bundleIdentifier,
              defaults.persistentDomain(forName: bundleID)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        var settings: [String: Any] = [:]
        for (key, value) in old {
            settings[key.replacingOccurrences(of: " Mini", with: " Tiller")] = value
        }
        defaults.setPersistentDomain(settings, forName: bundleID)
    }

    /// Removes the `mini` link that Install Command Line Tool made, now that
    /// the tool is called `tiller`. A `mini` that isn't that link is left alone.
    private static func removeOldCommandLink() {
        let path = NSHomeDirectory() + "/.local/bin/mini"
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              target.hasSuffix("/Mini.app/Contents/Helpers/mini") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
