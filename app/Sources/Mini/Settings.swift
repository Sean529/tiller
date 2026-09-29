import Foundation

/// Where address bar searches go.
enum SearchEngine: String, CaseIterable {
    case google
    case bing
    case duckduckgo
    case custom

    var displayName: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckduckgo: "DuckDuckGo"
        case .custom: "Custom"
        }
    }

    /// A search URL with `%s` where the query goes. Nil for `custom`.
    var template: String? {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .custom: nil
        }
    }
}

/// What Cmd+T opens.
enum NewTabPage: String, CaseIterable {
    case blank
    case homepage

    var displayName: String {
        switch self {
        case .blank: "Blank Page"
        case .homepage: "Homepage"
        }
    }
}

/// What opens when Mini starts.
enum LaunchTabs: String, CaseIterable {
    case restore
    case homepage

    var displayName: String {
        switch self {
        case .restore: "Tabs from Last Time"
        case .homepage: "Homepage"
        }
    }
}

/// Every setting the Settings window shows, stored in the app's user defaults.
/// Launch arguments (`-homepage https://…`) override them like any default.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static let defaultHomepage = "https://www.google.com/"

    /// As typed. Empty means the default.
    static var homepage: String {
        get { defaults.string(forKey: "homepage") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "homepage") }
    }

    /// The homepage as a URL to load.
    static var homepageURL: String {
        homepage.isEmpty ? defaultHomepage : AddressInput.url(for: homepage)
    }

    static var launchTabs: LaunchTabs {
        get { defaults.string(forKey: "launchTabs").flatMap(LaunchTabs.init) ?? .restore }
        set { defaults.set(newValue.rawValue, forKey: "launchTabs") }
    }

    static var newTabPage: NewTabPage {
        get { defaults.string(forKey: "newTabPage").flatMap(NewTabPage.init) ?? .blank }
        set { defaults.set(newValue.rawValue, forKey: "newTabPage") }
    }

    static var searchEngine: SearchEngine {
        get { defaults.string(forKey: "searchEngine").flatMap(SearchEngine.init) ?? .google }
        set { defaults.set(newValue.rawValue, forKey: "searchEngine") }
    }

    /// The custom engine's URL, with `%s` for the query.
    static var searchTemplate: String {
        get { defaults.string(forKey: "searchTemplate") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "searchTemplate") }
    }

    /// An http(s) URL with a host once `%s` is filled in.
    static func isValidSearchTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
            let url = URL(string: template.replacingOccurrences(of: "%s", with: "test")),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host() != nil
        else { return false }
        return true
    }

    /// The search URL for `query`. A custom template that isn't valid falls back to Google.
    static func searchURL(for query: String) -> String {
        var template = searchEngine.template ?? searchTemplate
        if !isValidSearchTemplate(template) { template = SearchEngine.google.template! }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return template.replacingOccurrences(of: "%s", with: encoded)
    }

    /// The CLI to run for `kind`, with `~` expanded. Nil means look it up.
    static func agentPath(for kind: AgentKind) -> String? {
        defaults.string(forKey: kind.pathDefaultsKey).flatMap { $0.isEmpty ? nil : NSString(string: $0).expandingTildeInPath }
    }

    static func setAgentPath(_ path: String, for kind: AgentKind) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            defaults.removeObject(forKey: kind.pathDefaultsKey)
        } else {
            defaults.set(path, forKey: kind.pathDefaultsKey)
        }
    }

    /// Added after Mini's own system prompt.
    static var agentInstructions: String {
        get { defaults.string(forKey: "agentInstructions") ?? "" }
        set { defaults.set(newValue, forKey: "agentInstructions") }
    }
}

extension Notification.Name {
    /// Posted when `AgentKind.current` changes, from the panel or from Settings.
    static let agentKindDidChange = Notification.Name("MiniAgentKindDidChange")
}
