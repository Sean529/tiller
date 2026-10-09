import Foundation

/// Brings over what each profile kept for itself while every profile ran in a
/// process of its own, now that one process runs them all: each profile's
/// Chromium data moves from `Profiles/<id>/Default` to `Chromium/<id>`, the
/// appearance, accent color and agent shortcut move to the app's defaults,
/// and the profiles' extensions join one list in the root folder, since
/// Chromium loads extensions into every profile of a process. Runs before
/// the core starts, which opens the Chromium data and loads the extensions.
@MainActor
enum SingleProcessMigration {
    private static let appKeys = ["appearance", "accentTheme", "agentShortcut"]

    static func run() {
        moveChromiumData()
        moveAppSettings()
        mergeExtensions()
    }

    /// Chromium's data per profile, once, while `Chromium/<id>` is missing.
    /// What Chromium kept beside it, such as `Local State`, starts afresh in
    /// `Chromium`, and the old copies are removed. A profile an older Tiller
    /// has open waits for the next launch; it can't open here meanwhile.
    private static func moveChromiumData() {
        let manager = FileManager.default
        for profile in Profiles.all where Profiles.runningProcess(profile.id) == nil {
            let folder = Profiles.folder(for: profile.id)
            let source = folder + "/Default", target = Profiles.cachePath(for: profile.id)
            guard manager.fileExists(atPath: source), !manager.fileExists(atPath: target) else { continue }
            do {
                try manager.createDirectory(atPath: Profiles.chromiumRoot, withIntermediateDirectories: true)
                try manager.moveItem(atPath: source, toPath: target)
            } catch {
                NSLog("Tiller: could not move %@: %@", source, error.localizedDescription)
                continue
            }
            for item in chromiumLeftovers {
                try? manager.removeItem(atPath: folder + "/" + item)
            }
        }
    }

    /// What Chromium kept in a profile's folder while it was its own data
    /// folder, besides `Default`.
    private static let chromiumLeftovers = [
        "Local State", "chrome_debug.log", "ChromeFeatureState", "component_crx_cache", "Dictionaries",
        "extensions_crx_cache", "First Run", "first_party_sets.db", "first_party_sets.db-journal",
        "GPUPersistentCache", "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "NativeMessagingHosts",
        "RunningChromeVersion", "Safe Browsing", "segmentation_platform", "SingletonCookie", "SingletonLock",
        "SingletonSocket", "Variations", "Crashpad", "Last Browser", "Last Version", "BrowserMetrics",
        "CertificateRevocation", "OnDeviceHeadSuggestModel", "OptimizationHints", "Subresource Filter",
        "TrustTokenKeyCommitments", "WidevineCdm", "ZxcvbnData", "hyphen-data", "MEIPreload",
        "SSLErrorAssistant", "FileTypePolicies", "OriginTrials", "PKIMetadata", "PrivacySandboxAttestationsPreloaded",
        "Crowd Deny", "AutofillStates", "AmountExtractionHeuristicRegexes", "CookieReadinessList",
        "Webstore Downloads", "screen_ai", "TpcdMetadata", "ProbabilisticRevealTokenRegistry",
    ]

    /// Profiles in the order their choices win: the one used last first.
    private static var profiles: [String] {
        let last = Profiles.lastUsed.id
        return [last] + Profiles.all.map(\.id).filter { $0 != last }
    }

    /// Takes each app-wide setting from the first profile that has it,
    /// unless the app has it already.
    private static func moveAppSettings() {
        let standard = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap(standard.persistentDomain(forName:)) ?? [:]
        for key in appKeys where domain[key] == nil {
            for id in profiles {
                guard let value = standard.persistentDomain(forName: Profiles.suiteName(for: id))?[key] else { continue }
                standard.set(value, forKey: key)
                break
            }
        }
    }

    /// Joins the profiles' `extensions.json` lists into the root's, once,
    /// while there is none. An extension in several profiles is kept once,
    /// on if any profile had it on. Folders Tiller made move to the root's
    /// `Extensions`, so deleting a profile doesn't take them along.
    private static func mergeExtensions() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: ExtensionStore.listPath) else { return }
        var merged: [ExtensionStore.Entry] = []
        var ids: [String: Int] = [:]
        for id in profiles {
            let folder = Profiles.folder(for: id)
            guard let data = manager.contents(atPath: folder + "/extensions.json"),
                let entries = try? JSONDecoder().decode([ExtensionStore.Entry].self, from: data)
            else { continue }
            for var entry in entries {
                let manifestID = (try? ExtensionManifest.read(entry.path))?.id
                if let index = merged.firstIndex(where: { $0.path == entry.path })
                    ?? manifestID.flatMap({ ids[$0] }) {
                    merged[index].enabled = merged[index].enabled || entry.enabled
                    merged[index].pinned = merged[index].pinned || entry.pinned
                    continue
                }
                if entry.source.owned, entry.path.hasPrefix(folder + "/Extensions/") {
                    let target = ExtensionStore.folder + "/" + URL(fileURLWithPath: entry.path).lastPathComponent
                    do {
                        try manager.createDirectory(atPath: ExtensionStore.folder, withIntermediateDirectories: true)
                        try manager.moveItem(atPath: entry.path, toPath: target)
                        entry.path = target
                    } catch {
                        NSLog("Tiller: could not move %@: %@", entry.path, error.localizedDescription)
                    }
                }
                if let manifestID { ids[manifestID] = merged.count }
                merged.append(entry)
            }
        }
        guard !merged.isEmpty else { return }
        do {
            try manager.createDirectory(atPath: Profiles.root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(merged).write(to: URL(fileURLWithPath: ExtensionStore.listPath), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ExtensionStore.listPath)
        } catch {
            NSLog("Tiller: could not merge extensions: %@", error.localizedDescription)
        }
    }
}
