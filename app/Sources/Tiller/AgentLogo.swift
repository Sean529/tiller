import AppKit

extension AgentKind {
    @MainActor private static var logos: [AgentKind: NSImage] = [:]

    /// The agent's logo in its own colors, `size` points square, from
    /// Resources/Agents in the app bundle. Nil when there is no such file.
    @MainActor
    func logo(size: CGFloat) -> NSImage? {
        if Self.logos[self] == nil {
            Self.logos[self] = Bundle.main
                .url(forResource: rawValue, withExtension: "svg", subdirectory: "Agents")
                .flatMap(NSImage.init(contentsOf:))
        }
        guard let image = Self.logos[self]?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }
}
