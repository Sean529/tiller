import AppKit

/// A transcript row holding wrapping text, which needs to know the width it
/// gets to report its height.
@MainActor
protocol TranscriptRow: NSView {
    func fit(width: CGFloat)
}

/// The scrolling column of messages. Flipped so rows stack from the top.
final class TranscriptView: NSView {
    private let stack = NSStackView()
    private static let inset: CGFloat = 14
    private var lastWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { stack.arrangedSubviews.isEmpty }

    /// The group taking tool calls until any other row, or `closeToolGroup()`.
    private var openGroup: ToolGroupView?

    /// Tool calls that follow one another go into one group; any other row
    /// ends the group.
    func add(_ row: NSView) {
        if let call = row as? ToolRowView {
            if let openGroup {
                openGroup.add(call)
                needsLayout = true
            } else {
                let group = ToolGroupView(first: call)
                add(group)
                openGroup = group
            }
            return
        }
        closeToolGroup()
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if lastWidth > 0 { Self.fit(row, width: lastWidth) }
        needsLayout = true
    }

    /// Ends the current run of tool calls, folding them under their header.
    func closeToolGroup() {
        openGroup?.close()
        openGroup = nil
    }

    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        openGroup = nil
    }

    /// Whether the bottom of the transcript is in view, give or take a line.
    func isNearBottom(of scrollView: NSScrollView) -> Bool {
        scrollView.contentView.bounds.maxY >= frame.height - 40
    }

    /// Only a width change re-measures every row; new rows are measured as
    /// they are added.
    override func layout() {
        let width = bounds.width - 2 * Self.inset
        if width != lastWidth, width > 0 {
            lastWidth = width
            for row in stack.arrangedSubviews { Self.fit(row, width: width) }
        }
        super.layout()
    }

    private static func fit(_ row: NSView, width: CGFloat) {
        if let row = row as? TranscriptRow {
            row.fit(width: width)
        } else if let label = row as? NSTextField, label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
    }
}

// MARK: Rows

/// A user message: its images, then a tinted bubble with its text, on the right.
final class UserMessageView: NSView, TranscriptRow {
    private let bubble = NSView()
    private let label: NSTextField
    /// Room kept free to the bubble's left, so it reads as a reply side.
    private static let leftMargin: CGFloat = 36
    private static let padding = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    /// `onOpenImage` gets the index of a clicked image.
    init(text: String, images: [NSImage] = [], onOpenImage: ((Int) -> Void)? = nil) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.cornerCurve = .continuous
        let grid = ThumbnailGrid(side: 64, alignment: .trailing)
        grid.images = images
        grid.onOpen = onOpenImage
        for view in [grid, bubble, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(grid)
        addSubview(bubble)
        bubble.addSubview(label)
        bubble.isHidden = text.isEmpty
        let p = Self.padding
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftMargin),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.isEmpty
                ? grid.bottomAnchor.constraint(equalTo: bottomAnchor)
                : bubble.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: images.isEmpty ? 0 : 6),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.leftMargin),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: p.top),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -p.bottom),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p.left),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p.right),
        ])
        if !text.isEmpty { bubble.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - Self.leftMargin - Self.padding.left - Self.padding.right
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        bubble.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
    }
}

/// Square image thumbnails in rows that wrap to the grid's width. Clicking one
/// opens it; with `onRemove` set, each also gets a remove button.
final class ThumbnailGrid: NSView {
    enum Alignment { case leading, trailing }

    var onOpen: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var images: [NSImage] = [] {
        didSet { rebuild() }
    }

    private let side: CGFloat
    private let alignment: Alignment
    private var thumbnails: [ThumbnailView] = []
    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    init(side: CGFloat, alignment: Alignment) {
        self.side = side
        self.alignment = alignment
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        thumbnails.forEach { $0.removeFromSuperview() }
        thumbnails = images.enumerated().map { index, image in
            let thumbnail = ThumbnailView(image: image, removable: onRemove != nil)
            thumbnail.onOpen = { [weak self] in self?.onOpen?(index) }
            thumbnail.onRemove = { [weak self] in self?.onRemove?(index) }
            addSubview(thumbnail)
            return thumbnail
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Before the grid has a width, everything goes in one row.
    private var perRow: Int {
        guard bounds.width > 0 else { return max(1, images.count) }
        return max(1, Int((bounds.width + Self.spacing) / (side + Self.spacing)))
    }

    override var intrinsicContentSize: NSSize {
        let rows = (images.count + perRow - 1) / perRow
        return NSSize(width: NSView.noIntrinsicMetric, height: rows == 0 ? 0 : CGFloat(rows) * (side + Self.spacing) - Self.spacing)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let perRow = perRow
        for (index, thumbnail) in thumbnails.enumerated() {
            let column = CGFloat(index % perRow), row = CGFloat(index / perRow)
            let offset = column * (side + Self.spacing)
            let x = alignment == .leading ? offset : bounds.width - side - offset
            thumbnail.frame = NSRect(x: x, y: row * (side + Self.spacing), width: side, height: side)
        }
    }
}

/// One thumbnail: the image filling a rounded square, with an optional
/// remove button in its corner.
private final class ThumbnailView: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let image: NSImage

    init(image: NSImage, removable: Bool) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Click to preview"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Image")
        guard removable else { return }
        let remove = NSButton()
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove Image")?
            .withSymbolConfiguration(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.toolTip = "Remove"
        remove.target = self
        remove.action = #selector(removeClicked(_:))
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked(_ sender: Any?) { onRemove?() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

/// One tool call: a spinner, then a check or a cross, beside the tool and
/// what it acted on. A running call shows a few lines of its arguments; a
/// finished one keeps a single line. A failed call adds the first line of
/// its error. With `disclosure`, the row is the clickable header of a
/// `ToolGroupView`, with a chevron for its state.
final class ToolRowView: NSView, TranscriptRow {
    enum Outcome { case running, done, failed, unfinished }

    /// The tool's name without the MCP server prefix.
    private(set) var tool: String
    private(set) var outcome = Outcome.running
    /// Called when the call finishes, whichever way.
    var onFinish: (() -> Void)?
    /// Called when a disclosure row is clicked.
    var onToggle: (() -> Void)?
    var isExpanded = false {
        didSet { chevron?.image = Self.chevronImage(expanded: isExpanded) }
    }

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let chevron: NSImageView?
    private var heading: NSAttributedString

    /// `detail` is what `detail(_:)` made of the call's input.
    init(name: String, detail: String, disclosure: Bool = false) {
        tool = Self.tool(name)
        heading = Self.heading(tool: tool, detail: detail)
        chevron = disclosure ? NSImageView(image: Self.chevronImage(expanded: false)!) : nil
        super.init(frame: .zero)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        label.attributedStringValue = heading
        label.maximumNumberOfLines = disclosure ? 1 : 4
        label.lineBreakMode = .byTruncatingTail
        // Without this, a line cut by the limit ends at a word break with no
        // ellipsis when the text would have wrapped there.
        label.cell?.truncatesLastVisibleLine = true
        for view in [spinner, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        if let chevron {
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                chevron.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 12),
                label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            ])
            label.isSelectable = false
            setAccessibilityRole(.disclosureTriangle)
        } else {
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - 39 - (chevron == nil ? 0 : 18)
    }

    /// Changes what the row says. A group header counts its calls as they come.
    func update(name: String, detail: String) {
        tool = Self.tool(name)
        heading = Self.heading(tool: tool, detail: detail)
        label.attributedStringValue = heading
        setAccessibilityLabel(heading.string)
    }

    /// A nil `isError` means the call never finished: the agent stopped first.
    func finish(isError: Bool?, summary: String) {
        spinner.stopAnimation(nil)
        icon.isHidden = false
        let (symbol, description, color): (String, String, NSColor) = switch isError {
        case true?: ("xmark.circle.fill", "Failed", .systemRed)
        case false?: ("checkmark.circle.fill", "Done", .systemGreen)
        case nil: ("minus.circle.fill", "Didn't finish", .tertiaryLabelColor)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = color
        outcome = switch isError {
        case true?: .failed
        case false?: .done
        case nil: .unfinished
        }
        label.maximumNumberOfLines = 1
        if isError == true, !summary.isEmpty {
            let text = NSMutableAttributedString(attributedString: heading)
            text.append(NSAttributedString(string: "\n" + summary, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.systemRed,
            ]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 3
        }
        onFinish?()
    }

    // Clicks anywhere on a disclosure row toggle it, the label included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return chevron != nil && hit != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if chevron != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard chevron != nil else { return false }
        onToggle?()
        return true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }

    private static func tool(_ name: String) -> String {
        // Chats saved before the rename from Mini carry the old server name.
        let prefix = ["mcp__tiller__", "mcp__mini__"].first { name.hasPrefix($0) }
        return prefix.map { String(name.dropFirst($0.count)) } ?? name
    }

    private static func heading(tool: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: tool, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private static func chevronImage(expanded: Bool) -> NSImage? {
        NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Hide steps" : "Show steps")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    /// The arguments worth showing: where it acts, and what it types or runs.
    /// URLs lose their scheme and scripts their line breaks, so a row's one
    /// line holds what matters.
    static func detail(_ input: [String: Any]) -> String {
        var parts: [String] = []
        if let url = input["url"] {
            var address = "\(url)"
            for scheme in ["https://", "http://"] where address.hasPrefix(scheme) { address.removeFirst(scheme.count) }
            parts.append(address)
        }
        if let ref = input["ref"] { parts.append("ref \(ref)") } else if let selector = input["selector"] { parts.append("\(selector)") }
        if let text = input["text"] { parts.append("\"\(text)\"") }
        if let expression = input["expression"] { parts.append("\(expression)") }
        if let command = input["command"] { parts.append("\(command)") }
        if let pattern = input["pattern"] { parts.append("\(pattern)") }
        if let path = input["file_path"] ?? input["path"] { parts.append("\(path)") }
        if parts.isEmpty, let tab = input["tab_id"] { parts.append("tab \(tab)") }
        let string = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return string.count > 80 ? String(string.prefix(80)) + "…" : string
    }
}

/// A run of tool calls between messages, under a header that counts them.
/// The calls show while the run is under way and fold under the header when
/// it ends; clicking the header shows them again. A run of one call is just
/// that call, with no header.
final class ToolGroupView: NSView, TranscriptRow {
    private let header = ToolRowView(name: "", detail: "", disclosure: true)
    private let stack = NSStackView()
    private let rows = NSStackView()
    private var calls: [ToolRowView] = []
    private(set) var isOpen = true
    /// Set once the user clicked the header: closing then leaves their choice alone.
    private var toggled = false
    private var width: CGFloat = 0
    /// How far the calls sit in from the header. None when there is no header.
    private var indent: CGFloat { calls.count > 1 ? 12 : 0 }
    private var rowsLeading: NSLayoutConstraint!
    private var rowsWidth: NSLayoutConstraint!

    init(first: ToolRowView) {
        super.init(frame: .zero)
        for list in [stack, rows] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
            list.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(rows)
        header.onToggle = { [weak self] in
            guard let self else { return }
            toggled = true
            setExpanded(!header.isExpanded)
        }
        header.isExpanded = true
        rowsLeading = rows.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
        rowsWidth = rows.widthAnchor.constraint(equalTo: stack.widthAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsLeading, rowsWidth,
        ])
        add(first)
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ call: ToolRowView) {
        calls.append(call)
        call.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(call)
        call.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        call.onFinish = { [weak self] in self?.updateHeader() }
        rowsLeading.constant = indent
        rowsWidth.constant = -indent
        if width > 0 { fit(width: width) }
        updateHeader()
    }

    /// The run ended: the header takes its outcome and the calls fold away.
    func close() {
        guard isOpen else { return }
        isOpen = false
        if !toggled { setExpanded(false) }
        updateHeader()
    }

    func fit(width: CGFloat) {
        self.width = width
        header.fit(width: width)
        for call in calls { call.fit(width: width - indent) }
    }

    private func setExpanded(_ expanded: Bool) {
        header.isExpanded = expanded
        header.toolTip = expanded ? "Hide steps" : "Show steps"
        updateHeader()
    }

    private func updateHeader() {
        // One call has no header to reopen it from, so it stays in view.
        header.isHidden = calls.count < 2
        rows.isHidden = !header.isExpanded && calls.count > 1
        var names: [String] = []
        for call in calls where !names.contains(call.tool) { names.append(call.tool) }
        let failed = calls.filter { $0.outcome == .failed }.count
        header.update(
            name: "\(calls.count) steps" + (failed > 0 ? " · \(failed) failed" : ""),
            detail: names.joined(separator: ", ")
        )
        guard !isOpen else { return }
        let settled = calls.allSatisfy { $0.outcome == .done || $0.outcome == .failed }
        header.finish(isError: failed > 0 ? true : settled ? false : nil, summary: "")
    }
}

/// A quiet line in the middle, such as "Stopped".
final class NoteView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An error from the agent or its process, in a red-tinted box.
final class ErrorMessageView: NSView, TranscriptRow {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!)
        icon.contentTintColor = .systemRed
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - 42
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
    }
}

// MARK: Markdown

/// Renders the agent's markdown: headings, lists, quotes and fenced code by
/// line, bold, italics, code and links within a line, and pipe tables as
/// grids. Other block syntax stays as typed.
@MainActor
enum AgentMarkdown {
    private static let bodySize: CGFloat = 13
    private static let listIndent: CGFloat = 16

    /// A pipe table, its cells already rendered.
    struct Table {
        /// The lines it was parsed from, to tell whether it changed.
        let source: String
        let header: [NSAttributedString]
        let rows: [[NSAttributedString]]
    }

    enum Block {
        case text(NSAttributedString)
        case table(Table)
    }

    static func label(_ text: String) -> MarkdownMessageView {
        let view = MarkdownMessageView()
        view.text = text
        return view
    }

    /// The message as runs of text with the tables between them.
    static func blocks(_ text: String) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var pending: [String] = []
        var inFence = false
        func flush() {
            let text = render(pending.joined(separator: "\n"))
            pending.removeAll()
            if text.length > 0 { blocks.append(.text(text)) }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            } else if !inFence, let (table, end) = table(in: lines, at: index) {
                flush()
                blocks.append(.table(table))
                index = end
                continue
            }
            pending.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// The table whose header is the line at `start`, and the line after its
    /// last row. A table is a header, a line of dashes, then rows.
    private static func table(in lines: [String], at start: Int) -> (Table, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(lines[start])
        let delimiter = cells(lines[start + 1])
        guard !delimiter.isEmpty, delimiter.count == header.count, lines[start + 1].contains("-"),
            delimiter.allSatisfy({ cell in
                var dashes = Substring(cell)
                if dashes.hasPrefix(":") { dashes = dashes.dropFirst() }
                if dashes.hasSuffix(":") { dashes = dashes.dropLast() }
                return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
            })
        else { return nil }
        let alignments: [NSTextAlignment] = delimiter.map { cell in
            if cell.hasSuffix(":") { return cell.hasPrefix(":") ? .center : .right }
            return .left
        }
        var end = start + 2
        var rows: [[String]] = []
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|"), !trimmed.hasPrefix("```") else { break }
            var row = Array(cells(trimmed).prefix(header.count))
            row += Array(repeating: "", count: header.count - row.count)
            rows.append(row)
            end += 1
        }
        func styled(_ row: [String], font: NSFont) -> [NSAttributedString] {
            row.enumerated().map { column, cell in
                let text = inline(cell, font: font)
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 1
                style.alignment = alignments[column]
                text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                return text
            }
        }
        let table = Table(
            source: lines[start..<end].joined(separator: "\n"),
            header: styled(header, font: .systemFont(ofSize: bodySize, weight: .semibold)),
            rows: rows.map { styled($0, font: body) })
        return (table, end)
    }

    /// A table line's cells. A pipe after a backslash or inside backticks
    /// does not end a cell.
    private static func cells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var current = ""
        var inCode = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)
        // The pipes at either end of the line border the table.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inFence = false
        var previousBlank = false
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            // Runs of blank lines collapse into paragraph spacing.
            if !inFence && trimmed.isEmpty {
                previousBlank = true
                continue
            }
            if index > 0 && result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            }
            let start = result.length
            result.append(rendered(line, trimmed: trimmed, inFence: inFence))
            if previousBlank, start > 0 {
                // A gap before the paragraph that followed a blank line.
                let range = NSRange(location: start, length: result.length - start)
                result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                    let style = ((value as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                    style.paragraphSpacingBefore = 6
                    result.addAttribute(.paragraphStyle, value: style, range: subrange)
                }
            }
            previousBlank = false
        }
        return result
    }

    /// Lines rendered before, by their text after an F in a fence or a B
    /// outside. A streamed answer renders again with every few words, and
    /// all but its last line are the same each time.
    private static var renderedLines: [String: NSAttributedString] = [:]
    private static let renderedLinesLimit = 4000

    private static func rendered(_ line: String, trimmed: String, inFence: Bool) -> NSAttributedString {
        let key = (inFence ? "F" : "B") + line
        if let cached = renderedLines[key] { return cached }
        let text = inFence ? code(line) : block(line, trimmed: trimmed)
        if renderedLines.count >= renderedLinesLimit { renderedLines.removeAll(keepingCapacity: true) }
        renderedLines[key] = text
        return text
    }

    private static let body = NSFont.systemFont(ofSize: bodySize)

    private static func paragraph(indent: CGFloat = 0, firstLineIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    private static func block(_ line: String, trimmed: String) -> NSAttributedString {
        // Headings: "# Title" to "###### Title".
        if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
            trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6, trimmed[hashes] == " " {
            let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 15 : 14
            let text = inline(String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces),
                              font: .systemFont(ofSize: size, weight: .semibold))
            let style = paragraph()
            style.paragraphSpacingBefore = 4
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            return text
        }
        // Nested lists indent by two spaces a level.
        let depth = CGFloat((line.prefix(while: { $0 == " " }).count) / 2)
        let indent = listIndent * (depth + 1)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = inline("•\t" + trimmed.dropFirst(2), font: body)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: indent, firstLineIndent: indent - listIndent),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
            trimmed[dot...].hasPrefix(". ") {
            let number = trimmed[..<dot]
            let text = inline("\(number).\t" + trimmed[dot...].dropFirst(2), font: body)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: indent + 4, firstLineIndent: indent - listIndent),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if trimmed.hasPrefix(">") {
            let text = inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), font: body)
            let range = NSRange(location: 0, length: text.length)
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: 10), range: range)
            return text
        }
        let text = inline(line, font: body)
        text.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func code(_ line: String) -> NSAttributedString {
        let style = paragraph(indent: 10)
        style.lineSpacing = 1
        return NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
            .paragraphStyle: style,
        ])
    }

    /// Bold, italics, inline code and links in one line.
    private static func inline<S: StringProtocol>(_ text: S, font: NSFont) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: String(text), options: options)) ?? AttributedString(String(text))
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: whole)
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: range)
                result.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.08), range: range)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                }
            }
        }
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            result.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        return result
    }
}

/// An agent message: its text, with each table drawn as a grid.
final class MarkdownMessageView: NSView, TranscriptRow {
    private let stack = NSStackView()
    private var width: CGFloat = 0

    var text = "" {
        didSet { if text != oldValue { rebuild() } }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        for view in stack.arrangedSubviews { fit(view) }
    }

    private func fit(_ view: NSView) {
        guard width > 0 else { return }
        if let table = view as? MarkdownTableView {
            table.fit(width: width)
        } else if let label = view as? NSTextField {
            label.preferredMaxLayoutWidth = width
        }
    }

    /// Keeps the views whose kind of block is unchanged, so a streamed
    /// answer only rewrites the text it is still adding to.
    private func rebuild() {
        let blocks = AgentMarkdown.blocks(text)
        for (index, block) in blocks.enumerated() {
            let existing = index < stack.arrangedSubviews.count ? stack.arrangedSubviews[index] : nil
            switch block {
            case .text(let text):
                if let label = existing as? NSTextField {
                    label.attributedStringValue = text
                } else {
                    let label = NSTextField(wrappingLabelWithString: "")
                    label.isSelectable = true
                    // Lets links in the text be clicked.
                    label.allowsEditingTextAttributes = true
                    label.attributedStringValue = text
                    place(label, at: index, replacing: existing)
                }
            case .table(let table):
                if let view = existing as? MarkdownTableView {
                    view.table = table
                } else {
                    let view = MarkdownTableView()
                    view.table = table
                    place(view, at: index, replacing: existing)
                }
            }
        }
        for view in stack.arrangedSubviews.dropFirst(blocks.count) { view.removeFromSuperview() }
    }

    private func place(_ view: NSView, at index: Int, replacing existing: NSView?) {
        existing?.removeFromSuperview()
        stack.insertArrangedSubview(view, at: index)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fit(view)
    }
}

/// A markdown table: a bold header, a rule between rows, and cells that wrap
/// so the table never runs wider than the transcript.
final class MarkdownTableView: NSView {
    private static let padding = NSSize(width: 8, height: 5)
    private static let minimumColumn: CGFloat = 36

    private var labels: [[NSTextField]] = []
    private var width: CGFloat = 0
    private var tableSize = NSSize.zero
    /// Where each row starts, and the bottom of the last.
    private var rowEdges: [CGFloat] = []

    var table: AgentMarkdown.Table? {
        didSet {
            guard let table, table.source != oldValue?.source else { return }
            for label in labels.joined() { label.removeFromSuperview() }
            labels = ([table.header] + table.rows).map { row in
                row.map { text in
                    let label = NSTextField(wrappingLabelWithString: "")
                    label.isSelectable = true
                    label.allowsEditingTextAttributes = true
                    label.attributedStringValue = text
                    addSubview(label)
                    return label
                }
            }
            arrange()
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: tableSize.height) }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        arrange()
    }

    private func measure(_ label: NSTextField, width: CGFloat) -> NSSize {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let size = label.cell?.cellSize(forBounds: bounds) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func arrange() {
        guard width > 0, let columns = labels.first?.count, columns > 0 else { return }
        let padding = Self.padding
        let natural = (0..<columns).map { column in
            labels.map { measure($0[column], width: .greatestFiniteMagnitude).width }.max() ?? 0
        }
        // Narrow columns keep their width; the wide ones share what is left.
        let available = max(width - CGFloat(columns) * 2 * padding.width, CGFloat(columns) * Self.minimumColumn)
        var widths = natural
        if natural.reduce(0, +) > available {
            var remaining = available
            var left = columns
            var cap: CGFloat?
            for column in (0..<columns).sorted(by: { natural[$0] < natural[$1] }) {
                if cap == nil, natural[column] > remaining / CGFloat(left) {
                    cap = max(floor(remaining / CGFloat(left)), Self.minimumColumn)
                }
                if let cap {
                    widths[column] = cap
                } else {
                    remaining -= natural[column]
                    left -= 1
                }
            }
        }
        var y: CGFloat = 0
        rowEdges = [0]
        for row in labels {
            let heights = row.enumerated().map { measure($1, width: widths[$0]).height }
            let height = heights.max() ?? 0
            var x: CGFloat = 0
            for (column, label) in row.enumerated() {
                label.frame = NSRect(x: x + padding.width, y: y + padding.height, width: widths[column], height: heights[column])
                x += widths[column] + 2 * padding.width
            }
            y += height + 2 * padding.height
            rowEdges.append(y)
        }
        tableSize = NSSize(width: widths.reduce(0, +) + CGFloat(columns) * 2 * padding.width, height: y)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rowEdges.count > 1 else { return }
        let frame = NSRect(origin: .zero, size: tableSize).insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSRect(x: 0, y: 0, width: tableSize.width, height: rowEdges[1]).fill()
        NSColor.separatorColor.setFill()
        for edge in rowEdges.dropFirst().dropLast() {
            NSRect(x: 0, y: edge - 0.5, width: tableSize.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}
