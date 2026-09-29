import AppKit
import UniformTypeIdentifiers

/// Making Tiller the Mac's default browser, for web links and HTML files. It
/// applies to every profile: macOS knows only the app.
@MainActor
enum DefaultBrowser {
    private static let sample = URL(string: "https://example.com/")!

    /// Only a bundled Tiller.app can be chosen, not a bare `swift run` binary.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Any copy of Tiller counts, since macOS keeps the choice by bundle id.
    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: sample) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to use Tiller for http, https and HTML files. macOS confirms
    /// the change with its own dialog, which can be declined, so `done` gets
    /// whether Tiller is the default afterwards.
    static func makeDefault(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard isDefault else { return done(false) }
                    let workspace = NSWorkspace.shared
                    // Accepting the http change usually brings https along;
                    // setting it again would ask a second time.
                    let https = workspace.urlForApplication(toOpen: sample)
                    if Bundle(url: https ?? app)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                        workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
                    }
                    for type in [UTType.html, UTType("public.xhtml")].compactMap(\.self) {
                        workspace.setDefaultApplication(at: app, toOpen: type) { _ in }
                    }
                    NotificationCenter.default.post(name: .defaultBrowserDidChange, object: nil)
                    done(true)
                }
            }
        }
    }

    /// Shared by every profile, so it asks once, not once per profile.
    private static let askedKey = "askedDefaultBrowser"

    /// Once ever, asks whether to make Tiller the default. `-askedDefaultBrowser
    /// YES` skips it, for scripted launches.
    static func askOnce(on window: NSWindow?) {
        guard isAvailable, !UserDefaults.standard.bool(forKey: askedKey), !isDefault else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        let alert = NSAlert()
        alert.messageText = "Make Tiller your default browser?"
        alert.informativeText = "Links and HTML files from other apps will open in Tiller. You can change this later in Settings."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { makeDefault() }
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

/// Web links and HTML files other apps hand to Tiller. They open in the profile
/// used last, like a plain launch and the CLI, so with several profiles open,
/// the one macOS happened to pick passes them on.
@MainActor
enum IncomingLinks {
    /// The profile used last just before this Tiller last became active. A
    /// clicked link activates the Tiller it's sent to, which then marks its own
    /// profile as used, possibly before the link arrives.
    private static var lastUsedBeforeActivation: (id: String, at: Date)?

    static func willBecomeActive() {
        lastUsedBeforeActivation = (Profiles.lastUsedID, Date())
    }

    /// The profile that should open links arriving now.
    private static var target: String {
        if let (id, at) = lastUsedBeforeActivation, Date().timeIntervalSince(at) < 2 { return id }
        return Profiles.lastUsedID
    }

    /// Opens `urls` with `openHere`, or in the Tiller of the profile used last.
    static func route(_ urls: [URL], openHere: @escaping @MainActor ([URL]) -> Void) {
        let urls = urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased()) }
        guard !urls.isEmpty else { return }
        let id = target
        guard id != Profiles.current.id else { return openHere(urls) }
        guard let pid = Profiles.runningProcess(id) else {
            // Its Tiller starts with the links.
            Profiles.open(id, urls: urls)
            return
        }
        let path = Profiles.socketPath(for: id)
        let strings = urls.map(\.absoluteString)
        Task {
            let sent = await Task.detached { strings.allSatisfy { ControlClient.newTab($0, socket: path) } }.value
            guard sent else {
                // It may have been started with TILLER_SOCKET, or be quitting.
                return openHere(urls)
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
    }
}

/// A one-shot client for another Tiller's control socket, the same line-based
/// JSON that tiller_mcp speaks.
enum ControlClient {
    /// Opens `url` in a new selected tab. False when the socket can't be
    /// reached or the request fails.
    nonisolated static func newTab(_ url: String, socket path: String) -> Bool {
        let request: [String: Any] = ["id": 1, "method": "tabs.new", "params": ["url": url, "select": true]]
        guard let line = try? JSONSerialization.data(withJSONObject: request),
            let reply = send(line + Data("\n".utf8), to: path),
            let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { return false }
        return object["result"] != nil
    }

    /// Writes `data` and returns the first reply line.
    nonisolated private static func send(_ data: Data, to path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(UInt8(ascii: "\n")) {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            reply.append(contentsOf: chunk.prefix(count))
        }
        return reply.prefix { $0 != UInt8(ascii: "\n") }
    }
}

extension Notification.Name {
    /// Posted when Tiller becomes the default browser.
    static let defaultBrowserDidChange = Notification.Name("TillerDefaultBrowserDidChange")
}
