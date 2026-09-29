import Foundation

/// Where Tiller keeps its data: `~/Library/Application Support/Tiller`, or the
/// folder in `TILLER_DATA_DIR`. The core (Chromium's profile) and tiller_mcp (the
/// control socket) read the same variable, so a second Tiller can run on a
/// separate profile.
enum DataDirectory {
    static let path: String = {
        if let dir = ProcessInfo.processInfo.environment["TILLER_DATA_DIR"], !dir.isEmpty { return dir }
        return NSHomeDirectory() + "/Library/Application Support/Tiller"
    }()

    /// `name` inside the folder, which is created if missing.
    static func file(_ name: String) -> String {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path + "/" + name
    }
}
