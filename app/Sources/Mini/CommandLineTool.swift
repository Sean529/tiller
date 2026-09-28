import AppKit

/// Puts the bundled `mini` CLI on the user's PATH as a symlink in ~/.local/bin.
@MainActor
enum CommandLineTool {
    static var linkPath: String { NSHomeDirectory() + "/.local/bin/mini" }

    /// Creates or replaces the symlink. A real file at that path is left alone.
    static func install() throws {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mini").path
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ControlError("This copy of Mini has no command-line tool. Rebuild it with scripts/bundle.sh.")
        }
        let files = FileManager.default
        try files.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // attributesOfItem doesn't follow links, so this also sees a broken one.
        if let type = (try? files.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType {
            guard type == .typeSymbolicLink else {
                throw ControlError("\(linkPath) already exists and is not a link. Move it away and try again.")
            }
            try files.removeItem(atPath: linkPath)
        }
        try files.createSymbolicLink(atPath: linkPath, withDestinationPath: tool)
    }

    /// Installs, then tells the user how it went, including when their shell
    /// won't find the link.
    static func installAndReport() async {
        let alert = NSAlert()
        do {
            try install()
            // A login shell, since Mini's own PATH is Finder's minimal one.
            let found = await Task.detached { AgentEnvironment.loginShellLookup("mini") }.value
            alert.messageText = "Installed the mini command"
            var info = "\(linkPath) now points to the mini tool inside this app. Run `mini --help` in Terminal to start."
            if found == nil {
                info += "\n\n~/.local/bin doesn't seem to be on your PATH. Add this to ~/.zshrc:\nexport PATH=\"$HOME/.local/bin:$PATH\""
            } else if let found, found != linkPath {
                info += "\n\nAnother mini at \(found) comes first on your PATH, so your shell runs that one."
            }
            info += "\n\nIf you move Mini, install again."
            alert.informativeText = info
        } catch let error as ControlError {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the mini command"
            alert.informativeText = error.message
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the mini command"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
