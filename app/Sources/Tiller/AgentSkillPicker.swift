import AppKit

/// The list that opens above the message field while it holds a `/` and the
/// start of a skill's name: matching skills with what they do. Arrow keys
/// move the selection, and Tab, Return or a click completes the name. It
/// sits on the same material as the address bar's suggestions.
final class SkillPicker: NSVisualEffectView {
    var onPick: ((AgentSkill) -> Void)?

    private let stack = NSStackView()
    private var rows: [SkillPickerRow] = []
    private(set) var skills: [AgentSkill] = []
    private var selected = 0
    private static let maxRows = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Skills")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Skills whose name starts with `query` come first, then those that
    /// have it elsewhere in the name. Returns whether any matched.
    @discardableResult
    func show(_ all: [AgentSkill], matching query: String) -> Bool {
        let query = query.lowercased()
        let starts = all.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = query.isEmpty ? [] : all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        let matches = Array((starts + contains).prefix(Self.maxRows))
        if matches.map(\.name) != skills.map(\.name) {
            skills = matches
            selected = 0
            rows.forEach { $0.removeFromSuperview() }
            rows = matches.enumerated().map { index, skill in
                let row = SkillPickerRow(skill: skill)
                row.onHover = { [weak self] in self?.select(index) }
                row.onClick = { [weak self] in self?.onPick?(skill) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                return row
            }
            select(0)
        }
        isHidden = matches.isEmpty
        return !matches.isEmpty
    }

    func moveSelection(by offset: Int) {
        guard !skills.isEmpty else { return }
        select((selected + offset + skills.count) % skills.count)
    }

    var selectedSkill: AgentSkill? { skills.indices.contains(selected) ? skills[selected] : nil }

    private func select(_ index: Int) {
        selected = index
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
    }

    // A material view doesn't reliably call `updateLayer`, so the plate's
    // shape and border are set when it joins a window and when the
    // appearance changes, as the suggestions plate does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shapePlate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shapePlate()
    }

    private func shapePlate() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.plate
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.cgColor
        }
    }
}

/// One skill in the picker: `/name`, its argument hint, and its description.
private final class SkillPickerRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private let name: NSTextField
    private let hint: NSTextField
    private let badge: NSTextField
    private let hasHint: Bool
    /// Between the name, the hint, the spacer and the badge.
    private static let spacing: CGFloat = 6
    private static let sideInset: CGFloat = 8

    init(skill: AgentSkill) {
        let argumentHint = skill.argumentHint ?? ""
        name = NSTextField(labelWithString: "/" + skill.name)
        hint = NSTextField(labelWithString: argumentHint)
        badge = NSTextField(labelWithString: skill.origin == .library ? "Tiller" : "")
        hasHint = !argumentHint.isEmpty
        super.init(frame: .zero)
        wantsLayer = true
        name.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hint.font = .systemFont(ofSize: Theme.FontSize.caption)
        hint.textColor = .tertiaryLabelColor
        // Never cut: a hint broken mid-token misleads, so `layout()` hides
        // it when it doesn't fit whole. It gives way to the row's width, and
        // under the split view's holding priority, so a long hint can't
        // widen the panel.
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.isHidden = !hasHint
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.isHidden = skill.origin != .library
        let top = NSStackView(views: [name, hint, NSView(), badge])
        top.spacing = Self.spacing
        let description = NSTextField(labelWithString: skill.description.isEmpty ? " " : skill.description)
        description.font = .systemFont(ofSize: Theme.FontSize.caption)
        description.textColor = .secondaryLabelColor
        description.lineBreakMode = .byTruncatingTail
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [top, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        toolTip = skill.description.isEmpty ? nil : skill.description
        setAccessibilityRole(.button)
        setAccessibilityLabel("/" + skill.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the hint only when the name, the hint and the badge all fit on
    /// the line. Decided before the stack lays out, so it lays out once.
    override func layout() {
        if hasHint, bounds.width > 0 {
            let available = bounds.width - 2 * Self.sideInset
            // The spacer between the hint and the badge adds one gap even at zero width.
            let badgeWidth = badge.isHidden ? 0 : Self.spacing + ceil(badge.intrinsicContentSize.width)
            let needed = ceil(name.intrinsicContentSize.width) + Self.spacing
                + ceil(hint.intrinsicContentSize.width) + Self.spacing + badgeWidth
            let hide = needed > available
            if hint.isHidden != hide { hint.isHidden = hide }
        }
        super.layout()
    }

    override var wantsUpdateLayer: Bool { true }

    /// The mouse selects the row it is over, so a pressed row is a selected
    /// one, and deepens its tint rather than turning grey.
    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill: NSColor = isSelected
            ? Theme.accent(isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(hovered: false, pressed: isPressed)
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.cgColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.selectionOutline(selected: isSelected).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
