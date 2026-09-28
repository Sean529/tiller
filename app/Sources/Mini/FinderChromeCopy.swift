import Foundation

/// Copies Chrome's files by asking Finder to do it. Security (EDR) software
/// can block Mini — and even Terminal — from opening anything under Chrome's
/// folder, but it virtually always lets Finder through, and the copies
/// themselves are readable by anyone. Mini only has to control Finder, which
/// is a normal Automation permission prompt.
enum FinderChromeCopy: Sendable {
    enum CopyError: LocalizedError {
        case automationDenied
        case nothingCopied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                "macOS didn't let Mini ask Finder for a copy. Allow Mini to control Finder in System Settings → Privacy & Security → Automation, then try again."
            case .nothingCopied:
                "Finder couldn't copy anything from Chrome's folder."
            case .failed(let message):
                "Finder couldn't copy Chrome's files: \(message)"
            }
        }
    }

    /// What the import reads from a profile. Journals go along so SQLite can
    /// finish or undo a write Chrome was in the middle of.
    private static let profileFiles = ["Cookies", "Login Data", "History", "Preferences"]
    private static let journalSuffixes = ["-journal", "-wal"]

    static func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-chrome-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Copies `Local State` so profiles can be listed from the copy.
    static func copyLocalState(to root: URL) throws {
        try duplicate([ChromeReader.defaultDataDirectory + "/Local State"], into: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Local State").path) else {
            throw CopyError.nothingCopied
        }
    }

    /// Copies one profile's databases and Preferences into `<root>/<directory>`,
    /// mirroring Chrome's layout so ChromeReader can read it unchanged.
    static func copyProfile(_ directory: String, to root: URL) throws {
        let destination = root.appendingPathComponent(directory)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = ChromeReader.defaultDataDirectory + "/" + directory
        var files: [String] = []
        for name in profileFiles {
            files.append(source + "/" + name)
            for suffix in journalSuffixes {
                files.append(source + "/" + name + suffix)
            }
        }
        try duplicate(files, into: destination)
        guard profileFiles.contains(where: {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
        }) else {
            throw CopyError.nothingCopied
        }
    }

    /// `duplicate <sources> into <destination>`; missing sources are skipped.
    /// Runs on a background thread — executeAndReturnError blocks until Finder
    /// finishes, and the first call waits on the Automation prompt.
    private static func duplicate(_ sources: [String], into destination: URL) throws {
        let paths = sources.map { quoted($0) }.joined(separator: ", ")
        // The file objects are built outside the tell block: inside it,
        // `POSIX file` resolves against Finder's dictionary and fails.
        let script = NSAppleScript(source: """
            set destFolder to (POSIX file \(quoted(destination.path))) as alias
            set srcs to {}
            repeat with p in {\(paths)}
                set end of srcs to (POSIX file (p as text))
            end repeat
            tell application "Finder"
                repeat with src in srcs
                    if exists src then duplicate src to destFolder with replacing
                end repeat
            end tell
            """)
        guard let script else { throw CopyError.failed("couldn't compile the Finder script") }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error { throw mapped(error) }
    }

    private static func quoted(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func mapped(_ error: NSDictionary?) -> Error {
        // errAEEventNotPermitted: the user (or a profile policy) denied Automation.
        if error?[NSAppleScript.errorNumber] as? Int == -1743 { return CopyError.automationDenied }
        return CopyError.failed(error?[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }
}
