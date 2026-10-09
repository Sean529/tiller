import Foundation

/// A profile's open tabs and recently closed ones, kept in `session.json` in
/// its folder so the next launch can bring them back and Cmd+Shift+T works
/// across restarts.
@MainActor
final class SessionStore {
    struct SavedTab: Codable, Equatable {
        var url: String
        var title: String

        var isBlank: Bool { url.isEmpty || url == "about:blank" }
    }

    struct ClosedTab: Codable, Equatable {
        var tab: SavedTab
        /// Where it was in the tab strip.
        var index: Int
    }

    private struct Session: Codable, Equatable {
        var tabs: [SavedTab] = []
        var selected = 0
        /// Most recently closed last.
        var closed: [ClosedTab] = []
    }

    private static let closedLimit = 25

    private let path: String
    private var session: Session
    private var writeScheduled = false

    init(folder: String) {
        path = folder + "/session.json"
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        session = data.flatMap { try? JSONDecoder().decode(Session.self, from: $0) } ?? Session()
    }

    /// The tabs open when Tiller last saved, in order.
    var openTabs: [SavedTab] { session.tabs }
    var selectedIndex: Int { session.selected }
    var hasClosedTabs: Bool { !session.closed.isEmpty }
    /// The closed tabs, most recent first, each URL once.
    var recentlyClosed: [SavedTab] {
        var seen = Set<String>()
        return session.closed.reversed().map(\.tab).filter { !$0.isBlank && seen.insert($0.url).inserted }
    }

    func setOpenTabs(_ tabs: [SavedTab], selected: Int) {
        guard tabs != session.tabs || selected != session.selected else { return }
        session.tabs = tabs
        session.selected = selected
        scheduleWrite()
    }

    func pushClosedTab(_ tab: SavedTab, at index: Int) {
        session.closed.append(ClosedTab(tab: tab, index: index))
        session.closed.removeFirst(max(0, session.closed.count - Self.closedLimit))
        closedTabsChanged()
    }

    func popClosedTab() -> ClosedTab? {
        guard let tab = session.closed.popLast() else { return nil }
        closedTabsChanged()
        return tab
    }

    func clearClosedTabs() {
        guard hasClosedTabs else { return }
        session.closed = []
        closedTabsChanged()
    }

    private func closedTabsChanged() {
        scheduleWrite()
        NotificationCenter.default.post(name: .closedTabsDidChange, object: self)
    }

    /// Writes a pending change now rather than after the short delay.
    func flush() {
        guard writeScheduled else { return }
        writeScheduled = false
        do {
            try JSONEncoder().encode(session).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            NSLog("Tiller: could not save session: %@", error.localizedDescription)
        }
    }

    /// Titles and URLs change several times per page load, so writes wait a moment.
    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }
}

extension Notification.Name {
    /// Posted when a tab joins or leaves the recently closed list.
    static let closedTabsDidChange = Notification.Name("TillerClosedTabsDidChange")
}
