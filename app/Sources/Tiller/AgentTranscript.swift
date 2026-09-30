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

    func add(_ row: NSView) {
        // Tool calls in a row sit closer together than other messages.
        if row is ToolRowView, let last = stack.arrangedSubviews.last, last is ToolRowView {
            stack.setCustomSpacing(4, after: last)
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if lastWidth > 0 { Self.fit(row, width: lastWidth) }
        needsLayout = true
    }

    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
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
/// what it acted on. A failed call adds the first line of its error.
final class ToolRowView: NSView, TranscriptRow {
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let heading: NSAttributedString

    /// `detail` is what `detail(_:)` made of the call's input.
    init(name: String, detail: String) {
        // Chats saved before the rename from Mini carry the old server name.
        let prefix = ["mcp__tiller__", "mcp__mini__"].first { name.hasPrefix($0) }
        let tool = prefix.map { String(name.dropFirst($0.count)) } ?? name
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
        heading = text
        super.init(frame: .zero)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        label.attributedStringValue = heading
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
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
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - 39
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
        guard isError == true, !summary.isEmpty else { return }
        let text = NSMutableAttributedString(attributedString: heading)
        text.append(NSAttributedString(string: "\n" + summary, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemRed,
        ]))
        label.attributedStringValue = text
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }

    /// The arguments worth showing: where it acts, and what it types or runs.
    static func detail(_ input: [String: Any]) -> String {
        var parts: [String] = []
        if let url = input["url"] { parts.append("\(url)") }
        if let ref = input["ref"] { parts.append("ref \(ref)") } else if let selector = input["selector"] { parts.append("\(selector)") }
        if let text = input["text"] { parts.append("\"\(text)\"") }
        if let expression = input["expression"] { parts.append("\(expression)") }
        if let command = input["command"] { parts.append("\(command)") }
        if let pattern = input["pattern"] { parts.append("\(pattern)") }
        if let path = input["file_path"] ?? input["path"] { parts.append("\(path)") }
        if parts.isEmpty, let tab = input["tab_id"] { parts.append("tab \(tab)") }
        let string = parts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        return string.count > 80 ? String(string.prefix(80)) + "…" : string
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
/// line, and bold, italics, code and links within a line. Tables and other
/// block syntax stay as typed.
@MainActor
enum AgentMarkdown {
    private static let bodySize: CGFloat = 13
    private static let listIndent: CGFloat = 16

    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        // Lets links in the text be clicked.
        label.allowsEditingTextAttributes = true
        label.attributedStringValue = render(text)
        return label
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
