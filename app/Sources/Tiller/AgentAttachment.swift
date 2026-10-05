import AppKit
import UniformTypeIdentifiers

/// A bitmap on its way to becoming an attachment, handed to a background
/// task. CGImage is immutable, which is what makes that safe.
struct AttachmentSource: @unchecked Sendable {
    let image: CGImage

    /// The image's bitmap, which may decode it, so it is taken on the main
    /// thread before the scaling and encoding leave it.
    init?(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.image = cgImage
    }
}

/// An image attached to an agent message, scaled down and saved to a file.
/// Claude Code and Qoder CLI get its bytes; Codex and Quick Look read the file.
/// Made off the main thread; nothing changes it after.
struct AgentAttachment: @unchecked Sendable {
    let url: URL
    let data: Data
    let mediaType: String
    /// A small copy for the composer's and the message's thumbnails. The
    /// file holds the image itself.
    let image: NSImage

    static let maxCount = 5
    /// The long edge is scaled down to this many pixels.
    private static let maxPixels = 2000
    /// PNGs larger than this are sent as JPEG, to stay under the APIs' image size limits.
    private static let maxPNGBytes = 3_500_000
    /// The long edge of the thumbnail kept in memory, enough for a 64-point
    /// thumbnail on a Retina screen with room to spare.
    private static let thumbnailPixels = 256

    /// Scales, encodes and writes the image. Slow for a screenshot, so it
    /// runs off the main thread.
    nonisolated init?(source: AttachmentSource, in directory: URL) {
        guard let scaled = Self.scaled(source.image),
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
        let small = Self.scaled(scaled, longEdge: Self.thumbnailPixels) ?? scaled
        self.image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    /// A small copy of the image file at `url`, at most `side` pixels on its
    /// long edge, made without decoding the whole image.
    static func thumbnail(at url: URL, side: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// `image` with its long edge brought down to `limit` pixels, or as it
    /// is when already that small.
    nonisolated private static func scaled(_ image: CGImage, longEdge limit: Int = maxPixels) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > limit else { return image }
        let scale = CGFloat(limit) / CGFloat(longEdge)
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
            // One more than a message holds, so a drop of too many still
            // beeps without every file being read.
            return imageFiles(on: pasteboard).prefix(maxCount + 1).compactMap(NSImage.init(contentsOf:))
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
