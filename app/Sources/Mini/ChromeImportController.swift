import AppKit
import CMiniCore

/// What an import can bring over.
enum ImportKind: CaseIterable, Sendable {
    case cookies
    case passwords
    case history
    case settings

    var title: String {
        switch self {
        case .cookies: "Cookies"
        case .passwords: "Saved passwords"
        case .history: "History"
        case .settings: "Search engine and homepage"
        }
    }

    var needsChromeKey: Bool { self == .cookies || self == .passwords }
}

/// One line of an import's result.
struct ImportResult: Sendable {
    let title: String
    let detail: String
    let error: Error?
}

/// Reads a Chrome profile and brings the chosen data into Mini.
@MainActor
enum ChromeImporter {
    /// Everything read from Chrome, gathered off the main thread.
    private struct Loaded: Sendable {
        var cookies: Result<(cookies: [ImportedCookie], skipped: Int), Error>?
        var logins: Result<(logins: [SavedLogin], skipped: Int), Error>?
        var history: Result<[HistoryPage], Error>?
        var preferences: Result<ChromePreferences, Error>?
    }

    static func run(profile: ChromeProfile, kinds: Set<ImportKind>) async -> [ImportResult] {
        let loaded = await Task.detached { load(ChromeReader(profile: profile), kinds) }.value
        var results: [ImportResult] = []

        if let preferences = loaded.preferences {
            switch preferences {
            case .success(let prefs): results += applySettings(prefs)
            case .failure(let error): results.append(ImportResult(title: "Search engine and homepage", detail: "", error: error))
            }
        }

        if let history = loaded.history {
            let result: Result<Int, Error>
            switch history {
            case .success(let pages):
                result = await withCheckedContinuation { continuation in
                    HistoryStore.shared.importPages(pages) { continuation.resume(returning: $0) }
                }
            case .failure(let error):
                result = .failure(error)
            }
            results.append(line("History", result.map { "\($0.formatted()) pages imported" }))
        }

        if let logins = loaded.logins {
            var result: Result<String, Error>
            do {
                let (logins, skipped) = try logins.get()
                let saved = try await PasswordStore.shared.merge(logins)
                result = .success("\(saved.formatted()) imported" + skippedNote(skipped, "never-saved, non-web or unreadable"))
            } catch {
                result = .failure(error)
            }
            results.append(line("Passwords", result))
        }

        if let cookies = loaded.cookies {
            var result: Result<String, Error>
            do {
                let (cookies, skipped) = try cookies.get()
                let (imported, failed) = await setCookies(cookies)
                var detail = "\(imported.formatted()) imported" + skippedNote(skipped, "partitioned, expired or unreadable")
                if failed > 0 { detail += ", \(failed.formatted()) rejected by Chromium" }
                result = .success(detail)
            } catch {
                result = .failure(error)
            }
            results.append(line("Cookies", result))
        }
        return results
    }

    nonisolated private static func load(_ reader: ChromeReader, _ kinds: Set<ImportKind>) -> Loaded {
        var loaded = Loaded()
        if kinds.contains(.settings) { loaded.preferences = Result { try reader.preferences() } }
        if kinds.contains(.history) { loaded.history = Result { try reader.history() } }
        guard kinds.contains(where: \.needsChromeKey) else { return loaded }
        // One keychain prompt covers both.
        let key = Result { try ChromeReader.safeStorageKey() }
        if kinds.contains(.passwords) { loaded.logins = Result { try reader.logins(key: key.get()) } }
        if kinds.contains(.cookies) { loaded.cookies = Result { try reader.cookies(key: key.get()) } }
        return loaded
    }

    private static func applySettings(_ prefs: ChromePreferences) -> [ImportResult] {
        var results: [ImportResult] = []
        if let url = prefs.searchURL {
            if let (engine, template) = searchSetting(for: url) {
                Settings.searchEngine = engine
                if let template { Settings.searchTemplate = template }
                results.append(ImportResult(title: "Search engine", detail: "Set to \(template ?? engine.displayName)", error: nil))
            } else {
                results.append(ImportResult(title: "Search engine", detail: "Chrome's engine (\(url)) can't be used; left unchanged", error: nil))
            }
        } else {
            results.append(ImportResult(title: "Search engine", detail: "Chrome uses its default; left unchanged", error: nil))
        }
        if let homepage = prefs.homepage {
            Settings.homepage = homepage
            results.append(ImportResult(title: "Homepage", detail: "Set to \(homepage)", error: nil))
        } else {
            results.append(ImportResult(title: "Homepage", detail: "Chrome opens its New Tab page; left unchanged", error: nil))
        }
        return results
    }

    /// Mini's engine for Chrome's search URL, with a template for a custom
    /// one. Chrome's URLs use `{searchTerms}` and other `{…}` parameters.
    static func searchSetting(for url: String) -> (SearchEngine, String?)? {
        let host = URL(string: url)?.host()?.lowercased() ?? ""
        if url.hasPrefix("{google:baseURL}") || host.hasPrefix("www.google.") || host.hasPrefix("google.") {
            return (.google, nil)
        }
        if host.hasSuffix("bing.com") { return (.bing, nil) }
        if host.hasSuffix("duckduckgo.com") { return (.duckduckgo, nil) }
        let template = url.replacingOccurrences(of: "{searchTerms}", with: "%s")
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        return Settings.isValidSearchTemplate(template) ? (.custom, template) : nil
    }

    private static func line(_ title: String, _ result: Result<String, Error>) -> ImportResult {
        switch result {
        case .success(let detail): ImportResult(title: title, detail: detail, error: nil)
        case .failure(let error): ImportResult(title: title, detail: "", error: error)
        }
    }

    private static func skippedNote(_ count: Int, _ reason: String) -> String {
        count > 0 ? ", \(count.formatted()) skipped (\(reason))" : ""
    }

    /// Hands the cookies to the core, which sets them through Chromium's
    /// cookie manager and flushes them to disk.
    private static func setCookies(_ cookies: [ImportedCookie]) async -> (imported: Int, failed: Int) {
        guard let data = try? JSONEncoder().encode(cookies) else { return (0, cookies.count) }
        let json = String(decoding: data, as: UTF8.self)
        return await withCheckedContinuation { continuation in
            let ctx = Unmanaged.passRetained(CookieCompletion { continuation.resume(returning: ($0, $1)) }).toOpaque()
            mini_cookies_import(json, ctx) { ctx, imported, failed in
                guard let ctx else { return }
                Unmanaged<CookieCompletion>.fromOpaque(ctx).takeRetainedValue().done(Int(imported), Int(failed))
            }
        }
    }

    private final class CookieCompletion {
        let done: (Int, Int) -> Void
        init(_ done: @escaping (Int, Int) -> Void) { self.done = done }
    }
}

/// File > Import from Chrome…, shown as a sheet on the browser window.
@MainActor
final class ChromeImportController: NSWindowController {
    private let profilePopUp = NSPopUpButton()
    private var checkboxes: [(ImportKind, NSButton)] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let privacyButton = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private var profiles: [ChromeProfile] = []
    private var finished = false
    private var onEnd: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        buildContent()
        loadProfiles()
    }

    required init?(coder: NSCoder) { fatalError() }

    func begin(on parent: NSWindow, onEnd: @escaping () -> Void) {
        guard let window else { return }
        self.onEnd = onEnd
        parent.beginSheet(window)
    }

    private func buildContent() {
        let heading = NSTextField(labelWithString: "Import from Google Chrome")
        heading.font = .boldSystemFont(ofSize: 13)

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.addRow(with: [NSTextField(labelWithString: "Profile:"), profilePopUp])
        for (index, kind) in ImportKind.allCases.enumerated() {
            let box = NSButton(checkboxWithTitle: kind.title, target: self, action: #selector(checkboxChanged(_:)))
            box.state = .on
            checkboxes.append((kind, box))
            grid.addRow(with: [index == 0 ? NSTextField(labelWithString: "Import:") : NSGridCell.emptyContentView, box])
        }
        grid.column(at: 0).xPlacement = .trailing
        // Otherwise the grid stretches to fill the sheet and one row or column takes the slack.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        grid.setContentHuggingPriority(.required, for: .vertical)

        let note = SettingsPane.note("For cookies and passwords, macOS asks for your login password so Mini can read Chrome's key. Imported cookies replace Mini's for the same site.")
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 420

        status.preferredMaxLayoutWidth = 420
        status.isSelectable = true
        status.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        privacyButton.target = self
        privacyButton.action = #selector(openPrivacySettings(_:))
        privacyButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importOrClose(_:))
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [spinner, privacyButton, NSView(), cancelButton, importButton])
        buttons.spacing = 8
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, grid, note, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(10, after: heading)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
    }

    private func loadProfiles() {
        do {
            let (profiles, lastUsed) = try ChromeReader.profiles()
            self.profiles = profiles
            for profile in profiles {
                profilePopUp.addItem(withTitle: profile.name == profile.directory ? profile.name : "\(profile.name) (\(profile.directory))")
            }
            profilePopUp.selectItem(at: profiles.firstIndex { $0.directory == lastUsed } ?? 0)
        } catch {
            profilePopUp.addItem(withTitle: "None found")
            setControlsEnabled(false)
            show([ImportResult(title: "Chrome", detail: "", error: error)])
        }
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        importButton.isEnabled = !selectedKinds.isEmpty
    }

    private var selectedKinds: Set<ImportKind> {
        Set(checkboxes.filter { $0.1.state == .on }.map(\.0))
    }

    private func setControlsEnabled(_ enabled: Bool) {
        profilePopUp.isEnabled = enabled
        checkboxes.forEach { $0.1.isEnabled = enabled }
        importButton.isEnabled = enabled && !selectedKinds.isEmpty
    }

    @objc private func importOrClose(_ sender: Any?) {
        if finished { return dismiss() }
        guard profiles.indices.contains(profilePopUp.indexOfSelectedItem) else { return }
        let profile = profiles[profilePopUp.indexOfSelectedItem]
        setControlsEnabled(false)
        cancelButton.isEnabled = false
        privacyButton.isHidden = true
        spinner.startAnimation(nil)
        status.isHidden = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Importing…"
        Task {
            let results = await ChromeImporter.run(profile: profile, kinds: selectedKinds)
            spinner.stopAnimation(nil)
            show(results)
            finished = true
            cancelButton.isHidden = true
            importButton.title = "Done"
            importButton.isEnabled = true
        }
    }

    private func show(_ results: [ImportResult]) {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        for (index, result) in results.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: body)) }
            var bold = body
            bold[.font] = NSFont.boldSystemFont(ofSize: 12)
            text.append(NSAttributedString(string: result.title + ": ", attributes: bold))
            var detail = body
            if result.error != nil { detail[.foregroundColor] = NSColor.systemRed }
            text.append(NSAttributedString(string: result.error?.localizedDescription ?? result.detail, attributes: detail))
        }
        status.attributedStringValue = text
        status.isHidden = false
        privacyButton.isHidden = !results.contains {
            if case ChromeImportError.noAccess? = $0.error { true } else { false }
        }
        window?.layoutIfNeeded()
    }

    @objc private func openPrivacySettings(_ sender: Any?) {
        NSWorkspace.shared.open(ChromeImportError.privacySettingsURL)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        onEnd?()
        onEnd = nil
    }
}
