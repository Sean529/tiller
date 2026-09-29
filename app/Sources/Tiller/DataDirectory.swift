import Foundation

/// Where the current profile keeps its data: `Profiles/<id>` in the root folder
/// (see `Profiles.root`). The core keeps Chromium's data here, and the control
/// socket that tiller_mcp connects to is here too.
enum DataDirectory {
    static let path = Profiles.folder(for: Profiles.current.id)

    /// `name` inside the folder, which is created if missing.
    static func file(_ name: String) -> String {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path + "/" + name
    }
}
