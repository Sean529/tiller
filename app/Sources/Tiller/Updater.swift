import AppKit
import Sparkle

/// Updates from GitHub Releases through Sparkle. Only release builds have a
/// feed: bundle.sh writes `SUFeedURL` when it signs with a Developer ID, so
/// ad-hoc builds never replace themselves with a release.
///
/// Sparkle keeps its own settings, such as the last check, in the standard
/// user defaults, which every profile's Tiller shares.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private nonisolated static let betaKey = "updateIncludesBetas"

    /// Whether updates include beta versions, which the appcast puts on the
    /// `beta` channel. For every profile.
    static var includesBetas: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: betaKey)
            shared.controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard Self.isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? ["beta"] : []
    }
}

extension Updater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}
