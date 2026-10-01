import AppKit
import CTillerCore

/// A file the browser is saving, or has saved, to ~/Downloads.
struct Download: Equatable {
    enum State: Int32 {
        case inProgress = 0
        case complete = 1
        case canceled = 2
        case failed = 3
    }

    let id: UInt32
    /// The browser id of the tab it came from, or -1.
    let tabID: Int32
    var path: String
    var url: String
    /// The URL asked for, before any redirect.
    var originalURL: String
    var received: Int64
    /// -1 while the size is unknown.
    var total: Int64
    var state: State

    /// The file's name, or the URL's last part before the path is chosen.
    var name: String {
        let file = (path as NSString).lastPathComponent
        if !file.isEmpty { return file }
        let last = URL(string: url)?.lastPathComponent ?? ""
        return last.isEmpty || last == "/" ? "Download" : last
    }

    /// How much has arrived, 0 to 1, or nil while the size is unknown.
    var fraction: Double? {
        total > 0 ? min(1, Double(received) / Double(total)) : nil
    }
}

/// The downloads of this run, newest first. The core reports each change
/// and the toolbar button and its list show them.
@MainActor
final class DownloadStore {
    static let shared = DownloadStore()

    private(set) var downloads: [Download] = []
    /// Called after any download changes.
    var onChange: (() -> Void)?
    /// Called once per download, when it first appears.
    var onStart: ((Download) -> Void)?

    private static let limit = 50

    private init() {}

    /// Starts taking reports from the core.
    func start() {
        tiller_core_set_download_handler(nil) { _, tabID, id, path, url, originalURL, received, total, state in
            let path = path.map { String(cString: $0) } ?? ""
            let url = url.map { String(cString: $0) } ?? ""
            let originalURL = originalURL.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                DownloadStore.shared.update(
                    Download(id: id, tabID: tabID, path: path, url: url, originalURL: originalURL, received: received,
                             total: total, state: Download.State(rawValue: state) ?? .failed))
            }
        }
    }

    var hasActive: Bool { downloads.contains { $0.state == .inProgress } }

    /// The progress of the downloads under way, together, or nil when none
    /// has a known size.
    var activeProgress: Double? {
        let active = downloads.filter { $0.state == .inProgress && $0.total > 0 }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.total }
        let received = active.reduce(0) { $0 + $1.received }
        return total > 0 ? min(1, Double(received) / Double(total)) : nil
    }

    private func update(_ download: Download) {
        var download = download
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            // The path arrives once it is chosen and stays after.
            if download.path.isEmpty { download.path = downloads[index].path }
            guard downloads[index] != download else { return }
            downloads[index] = download
        } else {
            downloads.insert(download, at: 0)
            if downloads.count > Self.limit { downloads.removeLast(downloads.count - Self.limit) }
            onStart?(download)
        }
        onChange?()
    }

    func cancel(_ id: UInt32) {
        tiller_download_cancel(id)
    }

    /// Forgets the downloads that have ended.
    func clearFinished() {
        downloads.removeAll { $0.state != .inProgress }
        onChange?()
    }
}

/// The toolbar's downloads button: an arrow, ringed with the progress of
/// the downloads under way. Hidden until the first download of the run.
final class DownloadsButton: NSButton {
    private var progress: Double?
    private var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .toolbar
        toolTip = "Downloads"
        setAccessibilityLabel("Downloads")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let store = DownloadStore.shared
        let progress = store.activeProgress
        let active = store.hasActive
        guard progress != self.progress || active != self.active || image == nil else { return }
        self.progress = progress
        self.active = active
        image = Self.image(progress: progress, active: active)
        toolTip = active
            ? progress.map { "Downloading, \(Int(($0 * 100).rounded()))%" } ?? "Downloading…"
            : "Downloads"
    }

    /// The arrow in a circle, which fills around as the download comes in.
    private static func image(progress: Double?, active: Bool) -> NSImage? {
        guard active else {
            return NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")
        }
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            track.stroke()
            if let progress {
                let done = NSBezierPath()
                done.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                    startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
                done.lineWidth = 2
                done.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                done.stroke()
            }
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            {
                let size = arrow.size
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                NSColor.labelColor.set()
                arrow.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.accessibilityDescription = "Downloads"
        return image
    }
}

/// The list the downloads button shows: each file with its progress or
/// outcome, a button to cancel or to show it in the Finder, and a button
/// to clear the finished ones. Rows are kept by download and updated in
/// place, so progress ticks don't rebuild the list under the mouse.
final class DownloadsController: NSViewController {
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No Downloads")
    private var rowViews: [UInt32: DownloadRowView] = [:]
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    private static let width: CGFloat = 320
    /// The list scrolls past this many rows' worth of height.
    private static let maxListHeight: CGFloat = 400

    override func loadView() {
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = NSAttributedString(string: "DOWNLOADS", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clear(_:))

        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 0

        // The document view follows the clip view's width and its rows' height.
        let document = DownloadListDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let view = NSView()
        for subview in [header, clearButton, scroll, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            scrollHeight,
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = view
        reload()
    }

    /// Brings the rows up to date with the store: new downloads get rows,
    /// gone ones lose them, and the rest update what they show.
    func reload() {
        let downloads = DownloadStore.shared.downloads
        var kept: [UInt32: DownloadRowView] = [:]
        for (index, download) in downloads.enumerated() {
            let row = rowViews[download.id] ?? DownloadRowView(download: download)
            row.update(download)
            if rows.arrangedSubviews.count <= index || rows.arrangedSubviews[index] !== row {
                rows.insertArrangedSubview(row, at: min(index, rows.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            kept[download.id] = row
        }
        for view in rows.arrangedSubviews where !(view is DownloadRowView && kept.values.contains { $0 === view }) {
            view.removeFromSuperview()
        }
        rowViews = kept
        emptyLabel.isHidden = !downloads.isEmpty
        clearButton.isHidden = !downloads.contains { $0.state != .inProgress }
        // The list's place holds the hint while it is empty.
        scroll.isHidden = downloads.isEmpty
        rows.layoutSubtreeIfNeeded()
        let listHeight = rows.fittingSize.height
        scrollHeight.constant = downloads.isEmpty ? 56 : min(listHeight, Self.maxListHeight)
        preferredContentSize = view.fittingSize
    }

    @objc private func clear(_ sender: Any?) {
        DownloadStore.shared.clearFinished()
    }
}

/// A view whose origin is at the top, so a list in it starts there.
private final class DownloadListDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One download: the file's icon, name and state, with a cancel button
/// while it is under way and a Finder button once it is on disk. A download
/// under way says how fast it is coming and how long is left. Clicking a
/// finished download opens the file.
private final class DownloadRowView: NSView {
    private var download: Download
    private var isHovered = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let action = NSButton()
    /// The path the icon was loaded for. Asking the Finder for an icon
    /// costs a trip to LaunchServices, so it happens once per file.
    private var iconPath: String?
    /// Recent (time, bytes) readings, for the speed.
    private var readings: [(time: TimeInterval, bytes: Int64)] = []

    init(download: Download) {
        self.download = download
        super.init(frame: .zero)
        wantsLayer = true

        icon.imageScaling = .scaleProportionallyUpOrDown

        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1

        action.isBordered = false
        action.bezelStyle = .accessoryBarAction
        action.imagePosition = .imageOnly
        action.contentTintColor = .secondaryLabelColor
        action.target = self

        let text = NSStackView(views: [name, detail, progress])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setCustomSpacing(4, after: detail)

        for view in [icon, text, action] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityRole(.button)
        update(download, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the download as it stands now.
    func update(_ download: Download, force: Bool = false) {
        let stateChanged = force || download.state != self.download.state
        self.download = download
        if download.state == .inProgress {
            let now = Date().timeIntervalSinceReferenceDate
            readings.append((now, download.received))
            readings.removeAll { now - $0.time > 5 }
        }
        if iconPath != download.path || force {
            iconPath = download.path
            icon.image = download.path.isEmpty
                ? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                : NSWorkspace.shared.icon(forFile: download.path)
        }
        if name.stringValue != download.name { name.stringValue = download.name }
        let text = detailText()
        if detail.stringValue != text { detail.stringValue = text }
        detail.textColor = download.state == .failed ? .systemRed : .secondaryLabelColor
        let indeterminate = download.fraction == nil
        if progress.isIndeterminate != indeterminate {
            progress.isIndeterminate = indeterminate
            if indeterminate && download.state == .inProgress { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        }
        progress.doubleValue = download.fraction ?? 0
        progress.isHidden = download.state != .inProgress
        if stateChanged {
            if download.state != .inProgress { progress.stopAnimation(nil) } else if indeterminate { progress.startAnimation(nil) }
            action.isHidden = false
            switch download.state {
            case .inProgress:
                action.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
                action.toolTip = "Cancel"
                action.action = #selector(cancel(_:))
            case .complete:
                action.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Show in Finder")
                action.toolTip = "Show in Finder"
                action.action = #selector(reveal(_:))
            case .canceled, .failed:
                action.isHidden = true
            }
            toolTip = download.url
            needsDisplay = true
        }
        setAccessibilityLabel("\(download.name), \(text)")
    }

    private static let bytes: ByteCountFormatter = {
        let format = ByteCountFormatter()
        format.countStyle = .file
        return format
    }()

    /// Bytes a second over the last few seconds, or nil before two readings.
    private var speed: Double? {
        guard let first = readings.first, let last = readings.last, last.time - first.time > 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    private func detailText() -> String {
        let format = Self.bytes
        switch download.state {
        case .inProgress:
            let received = format.string(fromByteCount: download.received)
            var text = download.total > 0 ? "\(received) of \(format.string(fromByteCount: download.total))" : received
            if let speed, speed > 0 {
                if download.total > 0 {
                    let left = Double(download.total - download.received) / speed
                    text += " · " + Self.timeLeft(left)
                } else {
                    text += " · \(format.string(fromByteCount: Int64(speed)))/s"
                }
            }
            return text
        case .complete:
            return format.string(fromByteCount: max(download.received, download.total))
        case .canceled:
            return "Canceled"
        case .failed:
            return "Failed"
        }
    }

    private static func timeLeft(_ seconds: Double) -> String {
        switch seconds {
        case ..<5: "A few seconds left"
        case ..<60: "\(Int(seconds.rounded())) seconds left"
        case ..<3600: "\(Int((seconds / 60).rounded())) min left"
        default: "\(Int((seconds / 3600).rounded())) hr left"
        }
    }

    @objc private func cancel(_ sender: Any?) {
        DownloadStore.shared.cancel(download.id)
    }

    @objc private func reveal(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.path)])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let hover = isHovered && download.state == .complete
        layer?.backgroundColor = (hover ? NSColor.labelColor.withAlphaComponent(0.06) : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard download.state == .complete, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: download.path))
    }

    override func accessibilityPerformPress() -> Bool {
        guard download.state == .complete else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: download.path))
        return true
    }
}
