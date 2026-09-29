import AppKit
import UniformTypeIdentifiers

/// An image attached to an agent message, scaled down and saved to a file.
/// Claude Code and Qoder CLI get its bytes; Codex and Quick Look read the file.
struct AgentAttachment {
    let url: URL
    let data: Data
    let mediaType: String
    let image: NSImage

    static let maxCount = 5
    /// The long edge is scaled down to this many pixels.
    private static let maxPixels = 2000
    /// PNGs larger than this are sent as JPEG, to stay under the APIs' image size limits.
    private static let maxPNGBytes = 3_500_000

    /// Where each panel keeps its chat's images, in a folder of its own.
    static let directory = URL(fileURLWithPath: DataDirectory.path + "/agent-attachments")

    init?(image: NSImage, in directory: URL) {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let scaled = Self.scaled(source),
            var data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        else { return nil }
        var mediaType = "image/png", ext = "png"
        if data.count > Self.maxPNGBytes,
            let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            (data, mediaType, ext) = (jpeg, "image/jpeg", "jpg")
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return nil
        }
        self.url = url
        self.data = data
        self.mediaType = mediaType
        self.image = NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
    }

    private static func scaled(_ image: CGImage) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixels else { return image }
        let scale = CGFloat(maxPixels) / CGFloat(longEdge)
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: Pasteboard

    private static let imageDataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    /// What the composer takes when dragged onto it.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL] + imageDataTypes

    /// Whether the pasteboard holds images to attach rather than text to insert.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(.fileURL) == true { return !imageFiles(on: pasteboard).isEmpty }
        return pasteboard.availableType(from: imageDataTypes) != nil
    }

    /// The images on the pasteboard. Copied files come first: Finder also puts
    /// the file's icon on the pasteboard, which isn't what the user copied.
    /// A copied image from a page often comes with its URL or HTML, and the
    /// image wins.
    static func images(on pasteboard: NSPasteboard) -> [NSImage] {
        if pasteboard.types?.contains(.fileURL) == true {
            return imageFiles(on: pasteboard).compactMap(NSImage.init(contentsOf:))
        }
        guard let type = pasteboard.availableType(from: imageDataTypes),
            let data = pasteboard.data(forType: type), let image = NSImage(data: data)
        else { return [] }
        return [image]
    }

    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
    }
}
