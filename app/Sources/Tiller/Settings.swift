import AppKit
import os

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

/// What opens when Tiller starts.
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

/// Where the browser's tabs go.
enum TabLayout: String, CaseIterable {
    case horizontal
    case vertical

    var displayName: String {
        switch self {
        case .horizontal: "Along the Top"
        case .vertical: "In a Sidebar"
        }
    }
}

/// Light or dark for the chrome and for pages, which see it as
/// `prefers-color-scheme`.
enum Appearance: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What `NSApp.appearance` is set to. Nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The color Tiller's own tinted surfaces use: selections, the message
/// bubble, busy dots and the start page's wash. AppKit's controls, such as
/// focus rings and text selection, keep the system accent either way.
enum AccentTheme: String, CaseIterable {
    case system
    case graphite
    case blue
    case teal
    case green
    case orange
    case pink

    var displayName: String {
        switch self {
        case .system: "Match System"
        case .graphite: "Graphite"
        case .blue: "Blue"
        case .teal: "Teal"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        }
    }

    /// A system color, so each one has its own light, dark and
    /// high-contrast shades.
    var color: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .graphite: .systemGray
        case .blue: .systemBlue
        case .teal: .systemTeal
        case .green: .systemGreen
        case .orange: .systemOrange
        case .pink: .systemPink
        }
    }
}

/// Every setting the Settings window shows, stored in the current profile's
/// user defaults. Launch arguments (`-homepage https://…`) override them like
/// any default.
enum Settings {
    static var defaults: UserDefaults { Profiles.defaults }

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

    static var tabLayout: TabLayout {
        get { defaults.string(forKey: "tabLayout").flatMap(TabLayout.init) ?? .horizontal }
        set {
            defaults.set(newValue.rawValue, forKey: "tabLayout")
            NotificationCenter.default.post(name: .tabLayoutDidChange, object: nil)
        }
    }

    static var appearance: Appearance {
        get { defaults.string(forKey: "appearance").flatMap(Appearance.init) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearance")
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    /// The accent last read or set. Every tinted color resolves it each time
    /// it is drawn, from any thread, so it skips the defaults lookup.
    private static let cachedAccentTheme = OSAllocatedUnfairLock<AccentTheme?>(initialState: nil)

    static var accentTheme: AccentTheme {
        get {
            cachedAccentTheme.withLock { cached in
                if let cached { return cached }
                let theme = defaults.string(forKey: "accentTheme").flatMap(AccentTheme.init) ?? .system
                cached = theme
                return theme
            }
        }
        set {
            cachedAccentTheme.withLock { $0 = newValue }
            defaults.set(newValue.rawValue, forKey: "accentTheme")
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    /// Whether the tab sidebar shows only icons.
    static var sidebarCollapsed: Bool {
        get { defaults.bool(forKey: "sidebarCollapsed") }
        set { defaults.set(newValue, forKey: "sidebarCollapsed") }
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

    /// Added after Tiller's own system prompt.
    static var agentInstructions: String {
        get { defaults.string(forKey: "agentInstructions") ?? "" }
        set { defaults.set(newValue, forKey: "agentInstructions") }
    }

    /// Built-in tools the agent gets besides Tiller's. All off by default.
    static func agentToolEnabled(_ tool: AgentTool) -> Bool {
        defaults.bool(forKey: tool.defaultsKey)
    }

    static func setAgentTool(_ tool: AgentTool, enabled: Bool) {
        defaults.set(enabled, forKey: tool.defaultsKey)
    }

    static var agentTools: [AgentTool] { AgentTool.allCases.filter(agentToolEnabled) }

    /// As typed. Empty means Tiller's own empty folder.
    static var agentFolder: String {
        get { defaults.string(forKey: "agentFolder") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agentFolder") }
    }

    /// The folder the agent works in, with `~` expanded. Nil means Tiller's own.
    static var agentFolderPath: String? {
        agentFolder.isEmpty ? nil : NSString(string: agentFolder).expandingTildeInPath
    }

    static let defaultAgentTabs = 3
    static let agentTabsRange = 1...9

    /// How many chats the agent panel keeps open in tabs at once.
    static var agentTabs: Int {
        get {
            let value = defaults.integer(forKey: "agentTabs")
            return value == 0 ? defaultAgentTabs : min(max(value, agentTabsRange.lowerBound), agentTabsRange.upperBound)
        }
        set {
            defaults.set(newValue, forKey: "agentTabs")
            NotificationCenter.default.post(name: .agentTabsDidChange, object: nil)
        }
    }

    static let defaultAgentShortcut = Shortcut(key: "s", modifiers: [.command, .shift])

    /// Shows and hides the agent panel. Stored as text like `shift+cmd+s`;
    /// unset means the default and empty means none.
    static var agentShortcut: Shortcut? {
        get {
            guard let text = defaults.string(forKey: "agentShortcut") else { return defaultAgentShortcut }
            return Shortcut(text: text)
        }
        set { defaults.set(newValue?.text ?? "", forKey: "agentShortcut") }
    }

    static func resetAgentShortcut() {
        defaults.removeObject(forKey: "agentShortcut")
    }
}

/// Groups of built-in agent tools that Settings can turn on.
enum AgentTool: String, CaseIterable, Codable {
    case read
    case write
    case shell

    var defaultsKey: String { "agentTool.\(rawValue)" }

    var displayName: String {
        switch self {
        case .read: "Read files"
        case .write: "Write and edit files"
        case .shell: "Run commands"
        }
    }

    /// The tool names Claude Code and Qoder CLI use.
    var toolNames: [String] {
        switch self {
        case .read: ["Read", "Grep", "Glob"]
        case .write: ["Write", "Edit"]
        case .shell: ["Bash"]
        }
    }
}

extension Notification.Name {
    /// Posted when `AgentKind.current` changes, from the panel or from Settings.
    static let agentKindDidChange = Notification.Name("TillerAgentKindDidChange")
    /// Posted when `Settings.agentTabs` changes.
    static let agentTabsDidChange = Notification.Name("TillerAgentTabsDidChange")
    /// Posted when `Settings.tabLayout` changes.
    static let tabLayoutDidChange = Notification.Name("TillerTabLayoutDidChange")
    /// Posted when `Settings.appearance` or `Settings.accentTheme` changes.
    static let themeDidChange = Notification.Name("TillerThemeDidChange")
}
