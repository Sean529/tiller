import AppKit
import Security

/// An endpoint the user added for an agent CLI, such as DeepSeek's
/// Anthropic-compatible API for Claude Code. Chats on it run the same CLI,
/// pointed at `baseURL` with the provider's key and models. The key is kept
/// in the Keychain, not here.
struct AgentProvider: Codable, Equatable {
    /// Which header the key goes in: Claude Code sends `ANTHROPIC_API_KEY` as
    /// `x-api-key` and `ANTHROPIC_AUTH_TOKEN` as a Bearer token.
    enum Auth: String, Codable, CaseIterable {
        case apiKey
        case authToken

        var displayName: String {
            switch self {
            case .apiKey: "API Key (x-api-key)"
            case .authToken: "Auth Token (Bearer)"
            }
        }

        var variable: String {
            switch self {
            case .apiKey: "ANTHROPIC_API_KEY"
            case .authToken: "ANTHROPIC_AUTH_TOKEN"
            }
        }
    }

    let id: String
    var name: String
    /// The CLI it runs. Only Claude Code for now.
    var kind: AgentKind
    var baseURL: String
    /// The first is used when the chat picks none.
    var models: [String]
    var auth: Auth
    /// `KEY=VALUE` lines, set after Tiller's own variables.
    var extraEnvironment: String

    init(name: String, baseURL: String, models: [String], auth: Auth, extraEnvironment: String) {
        id = UUID().uuidString
        self.name = name
        kind = .claude
        self.baseURL = baseURL
        self.models = models
        self.auth = auth
        self.extraEnvironment = extraEnvironment
    }

    /// `extraEnvironment` read as variables. Blank lines and `#` comments are
    /// skipped, a leading `export` is allowed, and quotes around a value go.
    static func variables(in text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            return (key, value)
        }
    }

    /// The variables Claude Code runs with on this provider: its URL and key,
    /// and `model` (or the provider's first) for every model role, so
    /// background requests such as titles don't ask it for a Claude model.
    /// Then the extra ones, which can override any of them.
    func apply(to env: inout [String: String], model: String?) {
        for key in env.keys where key.hasPrefix("ANTHROPIC_") { env[key] = nil }
        env["ANTHROPIC_BASE_URL"] = baseURL
        if let key = AgentProviderKeychain.read(id), !key.isEmpty { env[auth.variable] = key }
        if let model = model ?? models.first {
            for key in [
                "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
            ] {
                env[key] = model
            }
        }
        for (key, value) in Self.variables(in: extraEnvironment) { env[key] = value }
    }
}

/// The profile's providers, in its defaults.
@MainActor
final class AgentProviderStore {
    static let shared = AgentProviderStore()

    private static let defaultsKey = "agentProviders"
    private(set) var providers: [AgentProvider]

    private init() {
        providers = Settings.defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([AgentProvider].self, from: $0) } ?? []
    }

    func provider(_ id: String) -> AgentProvider? {
        providers.first { $0.id == id }
    }

    /// Adds or replaces it.
    func save(_ provider: AgentProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        write()
    }

    /// Chats on it stay in history, but can't run again. Its key goes too.
    func remove(_ id: String) {
        providers.removeAll { $0.id == id }
        AgentProviderKeychain.delete(id)
        if AgentChoice.current.provider == id { AgentChoice.current = AgentChoice(.claude) }
        write()
    }

    private func write() {
        Settings.defaults.set(try? JSONEncoder().encode(providers), forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .agentProvidersDidChange, object: nil)
    }
}

/// Providers' keys, one generic password each, by provider id.
enum AgentProviderKeychain {
    private static let service = "Tiller Agent Provider"

    private static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    static func read(_ id: String) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes it.
    static func write(_ key: String, for id: String) {
        delete(id)
        guard !key.isEmpty else { return }
        var add = query(id)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = service
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// What a chat or schedule runs: a CLI, on its own login or on a provider
/// the user added. Saved as the CLI's name, or `claude:<provider id>`.
struct AgentChoice: Hashable, RawRepresentable {
    var kind: AgentKind
    /// The provider's id. Nil uses the CLI's own setup.
    var provider: String?

    init(_ kind: AgentKind, provider: String? = nil) {
        self.kind = kind
        self.provider = provider
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let kind = AgentKind(rawValue: first) else { return nil }
        self.kind = kind
        provider = parts.count == 2 && !parts[1].isEmpty ? parts[1] : nil
    }

    var rawValue: String { provider.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    /// The provider's settings. Nil without one, or once it was removed.
    @MainActor
    var providerConfig: AgentProvider? { provider.flatMap(AgentProviderStore.shared.provider) }

    /// Whether it can run: a removed provider can't.
    @MainActor
    var exists: Bool { provider == nil || providerConfig != nil }

    /// Why it can't be picked: its CLI isn't there. Nil when it can, or
    /// while the CLI is still being looked up.
    @MainActor
    var unavailableReason: String? {
        guard AgentEnvironment.isAvailable(kind) == false else { return nil }
        if let path = Settings.agentPath(for: kind) {
            return "\(path) is not an executable file. Fix the \(kind.displayName) path in Settings (Cmd+,)."
        }
        return "\(kind.rawValue) not found. Install it, or set its path in Settings (Cmd+,)."
    }

    @MainActor
    var displayName: String {
        guard let provider else { return kind.displayName }
        return AgentProviderStore.shared.provider(provider)?.name ?? "Removed Provider"
    }

    @MainActor
    func logo(size: CGFloat) -> NSImage? { kind.logo(size: size) }

    /// Every CLI, then the providers.
    @MainActor
    static var all: [AgentChoice] {
        AgentKind.allCases.map { AgentChoice($0) } + AgentProviderStore.shared.providers.map { AgentChoice($0.kind, provider: $0.id) }
    }

    /// What new chats start with. A removed provider falls back to its CLI.
    @MainActor
    static var current: AgentChoice {
        get {
            guard let choice = Settings.defaults.string(forKey: "agent").flatMap(AgentChoice.init) else { return AgentChoice(.qodercli) }
            return choice.exists ? choice : AgentChoice(choice.kind)
        }
        set {
            guard newValue != current else { return }
            Settings.defaults.set(newValue.rawValue, forKey: "agent")
            NotificationCenter.default.post(name: .agentKindDidChange, object: nil)
        }
    }

    /// The options a new chat with it starts with.
    @MainActor
    var defaultModelOptions: AgentModelOptions { Settings.agentModelOptions(for: self) }
}

extension Notification.Name {
    /// Posted when a provider is added, changed or removed.
    static let agentProvidersDidChange = Notification.Name("TillerAgentProvidersDidChange")
}

/// Greys out the agents whose CLI isn't there in an agent pop-up's menu,
/// with why as the tooltip. Checked each time the menu opens, so a CLI
/// installed or given a path since then can be picked.
@MainActor
final class AgentMenuAvailability: NSObject, NSMenuDelegate {
    private static let shared = AgentMenuAvailability()

    /// `popUp`'s items name agents by `AgentChoice.rawValue`.
    static func watch(_ popUp: NSPopUpButton) {
        popUp.autoenablesItems = false
        popUp.menu?.delegate = shared
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let choice = (item.representedObject as? String).flatMap(AgentChoice.init) else { continue }
            let reason = choice.unavailableReason
            item.isEnabled = reason == nil
            item.toolTip = reason
        }
        AgentEnvironment.refreshAvailability()
    }
}
