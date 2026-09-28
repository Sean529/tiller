import Foundation

/// Where Mini keeps its data: `~/Library/Application Support/Mini`, or the
/// folder in `MINI_DATA_DIR`. The core (Chromium's profile) and mini_mcp (the
/// control socket) read the same variable, so a second Mini can run on a
/// separate profile.
enum DataDirectory {
    static let path: String = {
        if let dir = ProcessInfo.processInfo.environment["MINI_DATA_DIR"], !dir.isEmpty { return dir }
        return NSHomeDirectory() + "/Library/Application Support/Mini"
    }()

    /// `name` inside the folder, which is created if missing.
    static func file(_ name: String) -> String {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path + "/" + name
    }
}
