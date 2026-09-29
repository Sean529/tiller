import AppKit

/// A profile has its own cookies and site data, history, open tabs, saved
/// passwords, settings and agent chats. Each open profile is a separate Tiller
/// process working in `Profiles/<id>` under the root folder.
struct Profile: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var created: Date
}

enum ProfileError: LocalizedError {
    case emptyName
    case duplicateName(String)
    case current
    case running(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "A profile needs a name."
        case .duplicateName(let name): "There is already a profile called \(name)."
        case .current: "This window's profile can't be deleted. Open another profile and delete it from there."
        case .running(let name): "\(name) is open. Quit it first, then delete it."
        }
    }
}

/// Every profile, listed in `profiles.json` in the root folder with the one
/// used last, which a plain launch and the `tiller` CLI pick. All running
/// Tillers share the file, so each change re-reads it under `profiles.lock`.
enum Profiles {
    /// The profile that data from before profiles existed moved into.
    static let defaultID = "default"

    /// `~/Library/Application Support/Tiller`, or the folder in `TILLER_DATA_DIR`.
    /// tiller_mcp reads the same variable to find `profiles.json`.
    static let root: String = {
        if let dir = ProcessInfo.processInfo.environment["TILLER_DATA_DIR"], !dir.isEmpty { return dir }
        return NSHomeDirectory() + "/Library/Application Support/Tiller"
    }()

    static func folder(for id: String) -> String {
        root + "/Profiles/" + id
    }

    /// The profile this process runs: the one the `-profile` launch argument
    /// names by id or name, else the one used last. The first access creates
    /// the default profile when there is none.
    static let current: Profile = {
        let list = update { list in
            if list.profiles.isEmpty {
                list.profiles = [Profile(id: defaultID, name: "Default", created: Date())]
            }
        }
        return UserDefaults.standard.string(forKey: "profile").flatMap { find($0, in: list.profiles) }
            ?? list.lastUsed.flatMap { id in list.profiles.first { $0.id == id } }
            ?? list.profiles[0]
    }()

    /// This profile's settings, in a user defaults suite of its own. Launch
    /// arguments (`-homepage https://…`) still override them. UserDefaults is
    /// thread-safe, though not marked Sendable.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: suiteName(for: current.id)) ?? .standard

    static func suiteName(for id: String) -> String {
        (Bundle.main.bundleIdentifier ?? "dev.sorrycc.tiller") + ".profile." + id
    }

    /// In the order they were created.
    static var all: [Profile] { read().profiles }

    /// The current profile's name, which another Tiller may have changed.
    static var currentName: String {
        all.first { $0.id == current.id }?.name ?? current.name
    }

    static func find(_ idOrName: String, in profiles: [Profile]) -> Profile? {
        profiles.first { $0.id == idOrName }
            ?? profiles.first { $0.name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame }
    }

    /// Makes the current profile the one a plain launch and the CLI pick.
    static func markUsed() {
        update { $0.lastUsed = current.id }
    }

    static func create(named name: String) throws -> Profile {
        var profile: Profile?
        try update { list in
            let name = try validName(name, for: nil, in: list)
            var id: String
            repeat {
                id = String(UUID().uuidString.lowercased().prefix(8))
            } while list.profiles.contains { $0.id == id }
            profile = Profile(id: id, name: name, created: Date())
            list.profiles.append(profile!)
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
        return profile!
    }

    static func rename(_ id: String, to name: String) throws {
        try update { list in
            let name = try validName(name, for: id, in: list)
            guard let index = list.profiles.firstIndex(where: { $0.id == id }) else { return }
            list.profiles[index].name = name
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// Moves the profile's folder to the Trash and forgets its settings and
    /// password key. The current profile and open ones can't be deleted.
    static func delete(_ id: String) throws {
        guard id != current.id else { throw ProfileError.current }
        if runningProcess(id) != nil {
            throw ProfileError.running(all.first { $0.id == id }?.name ?? id)
        }
        update { list in
            list.profiles.removeAll { $0.id == id }
            if list.lastUsed == id { list.lastUsed = current.id }
        }
        let folder = URL(fileURLWithPath: folder(for: id))
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName(for: id))
        PasswordKey.delete(profileID: id)
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    private static func validName(_ name: String, for id: String?, in list: List) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.emptyName }
        // Names must differ, since `tiller --profile` picks one by name.
        if let other = find(name, in: list.profiles), other.id != id {
            throw ProfileError.duplicateName(other.name)
        }
        return name
    }

    // MARK: Opening

    /// Brings the profile's Tiller forward, or starts one for it.
    @MainActor
    static func open(_ id: String) {
        if let pid = runningProcess(id) {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-profile", id]
        // The new process must find the same profiles. TILLER_SOCKET isn't
        // passed on, since two processes can't share a socket.
        if let dir = ProcessInfo.processInfo.environment["TILLER_DATA_DIR"], !dir.isEmpty {
            configuration.environment = ["TILLER_DATA_DIR": dir]
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn't open the profile"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }

    // MARK: Instance lock

    private static func lockPath(for id: String) -> String {
        folder(for: id) + "/instance.lock"
    }

    /// Locks the current profile's `instance.lock` for the life of the process,
    /// so no other process opens the same profile. Returns the process that
    /// holds it already, or nil once this one does.
    static func claim() -> pid_t? {
        try? FileManager.default.createDirectory(atPath: folder(for: current.id), withIntermediateDirectories: true)
        let fd = Darwin.open(lockPath(for: current.id), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let pid = processID(in: fd)
            close(fd)
            return pid
        }
        ftruncate(fd, 0)
        let text = "\(getpid())"
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
        // The descriptor stays open, and the lock held, until the process exits.
        return nil
    }

    /// The process running profile `id`, or nil when none is.
    static func runningProcess(_ id: String) -> pid_t? {
        let fd = Darwin.open(lockPath(for: id), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return processID(in: fd)
    }

    /// The pid written in a lock file. 0 when unreadable, which activates nothing.
    private static func processID(in fd: Int32) -> pid_t {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return 0 }
        return pid_t(String(decoding: buffer.prefix(count), as: UTF8.self)) ?? 0
    }

    // MARK: File

    private struct List: Codable, Equatable {
        var profiles: [Profile] = []
        /// The id of the profile whose Tiller was active last.
        var lastUsed: String?
    }

    private static var listURL: URL { URL(fileURLWithPath: root + "/profiles.json") }

    private static func read() -> List {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: listURL)).flatMap { try? decoder.decode(List.self, from: $0) } ?? List()
    }

    /// Re-reads the list, applies `change` and writes it back if it changed,
    /// all while holding `profiles.lock`.
    @discardableResult
    private static func update(_ change: (inout List) throws -> Void) rethrows -> List {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root + "/profiles.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        var list = read()
        let before = list
        try change(&list)
        guard list != before else { return list }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(list).write(to: listURL, options: .atomic)
        } catch {
            NSLog("Tiller: could not save profiles: %@", error.localizedDescription)
        }
        return list
    }
}

/// Asks for a profile's name, as a sheet on `window` or, without one, as a
/// modal alert. `apply` gets the name; an error it throws is shown.
@MainActor
enum ProfileNamePrompt {
    static func run(
        _ message: String, button: String, initial: String = "", on window: NSWindow?,
        apply: @escaping @MainActor (String) throws -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try apply(field.stringValue)
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = error.localizedDescription
                if let window { failure.beginSheetModal(for: window) } else { failure.runModal() }
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }
}

extension Notification.Name {
    /// Posted when this process changes the profiles, and when Tiller becomes
    /// active, since another Tiller may have changed them.
    static let profilesDidChange = Notification.Name("TillerProfilesDidChange")
}
