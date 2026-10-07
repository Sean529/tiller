import AppKit

/// Where a URL the user chose opens, read from the modifier keys held, as in
/// Safari and Chrome.
enum OpenDisposition {
    case currentTab
    case foregroundTab
    case backgroundTab

    /// A click: Cmd opens a tab behind the current one, Cmd+Shift opens and
    /// selects it.
    static func click(_ flags: NSEvent.ModifierFlags) -> OpenDisposition {
        guard flags.contains(.command) else { return .currentTab }
        return flags.contains(.shift) ? .foregroundTab : .backgroundTab
    }

    /// Return in the address bar: Cmd opens and selects a new tab, Cmd+Shift
    /// opens it behind the current one.
    static func returnKey(_ flags: NSEvent.ModifierFlags) -> OpenDisposition {
        guard flags.contains(.command) else { return .currentTab }
        return flags.contains(.shift) ? .backgroundTab : .foregroundTab
    }

    /// The modifiers on the event being handled.
    @MainActor static var currentFlags: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? []
    }
}
