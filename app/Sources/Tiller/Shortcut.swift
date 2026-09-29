import AppKit

/// A key combination for a menu item, such as Cmd+Shift+S.
struct Shortcut: Equatable {
    static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// The menu key equivalent. Letters are lowercase, with Shift in `modifiers`.
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        let modifiers = modifiers.intersection(Self.allowedModifiers)
        // "S" as a key equivalent means Shift+S.
        if key.count == 1, key.lowercased() != key {
            self.key = key.lowercased()
            self.modifiers = modifiers.union(.shift)
        } else {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// The combination `event` types, shifted characters included ("{" for Shift+[).
    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        let modifiers = event.modifierFlags.intersection(Self.allowedModifiers)
        // Caps Lock alone uppercases letters too.
        self.init(key: modifiers.contains(.shift) ? key : key.lowercased(), modifiers: modifiers)
    }

    init?(menuItem: NSMenuItem) {
        guard !menuItem.keyEquivalent.isEmpty else { return nil }
        self.init(key: menuItem.keyEquivalent, modifiers: menuItem.keyEquivalentModifierMask)
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.key == b.key && a.modifiers == b.modifiers
    }

    private static let modifierNames: [(NSEvent.ModifierFlags, name: String, symbol: String)] = [
        (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    /// As stored in user defaults: `shift+cmd+s`. Parsing takes the modifiers in any order.
    var text: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map { $0.name + "+" }.joined() + key
    }

    init?(text: String) {
        var rest = Substring(text)
        var modifiers: NSEvent.ModifierFlags = []
        var matched = true
        while matched {
            matched = false
            for (flag, name, _) in Self.modifierNames where rest.hasPrefix(name + "+") {
                rest = rest.dropFirst(name.count + 1)
                modifiers.insert(flag)
                matched = true
            }
        }
        guard rest.count == 1 else { return nil }
        self.init(key: String(rest), modifiers: modifiers)
    }

    /// As menus show it: ⇧⌘S.
    var displayString: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.symbol).joined() + keyName
    }

    private var keyName: String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        case 0x0D, 0x03: return "↩"
        case 0x09, 0x19: return "⇥"
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case NSDeleteFunctionKey: return "⌦"
        default: return key.uppercased()
        }
    }
}

/// A button that records a shortcut: click it, then press the combination.
/// Escape cancels and Delete clears.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    /// Called with the combination pressed, or nil for Delete.
    var onRecord: ((Shortcut?) -> Void)?

    private var isRecording = false { didSet { updateTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(clicked(_:))
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    @objc private func clicked(_ sender: Any?) {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    /// Takes Cmd combinations before the menu does, so Cmd+T records instead of opening a tab.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Shortcut.allowedModifiers)
        if modifiers.isEmpty, event.keyCode == 53 {  // Escape
            isRecording = false
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {  // Delete, Forward Delete
            isRecording = false
            onRecord?(nil)
            return
        }
        guard let shortcut = Shortcut(event: event) else { return }
        isRecording = false
        onRecord?(shortcut)
    }

    private func updateTitle() {
        title = isRecording ? "Type Shortcut…" : shortcut?.displayString ?? "None"
    }
}
