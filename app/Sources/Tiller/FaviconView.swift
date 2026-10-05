import AppKit

/// A site's favicon. One too dark to see on a dark surface, or too light on
/// a light one, gets a plate of the other tone behind it.
final class FaviconView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            luminance = isTemplate ? nil : image.flatMap(Self.luminance)
            needsDisplay = true
        }
    }

    /// For symbols shown in a favicon's place.
    var contentTintColor: NSColor? {
        get { imageView.contentTintColor }
        set { imageView.contentTintColor = newValue }
    }

    var imageScaling: NSImageScaling {
        get { imageView.imageScaling }
        set { imageView.imageScaling = newValue }
    }

    private let imageView = NSImageView()
    private let plate = CALayer()
    /// How light the icon's pixels are on average, from 0 to 1. Nil for
    /// symbols, which take the text's color.
    private var luminance: CGFloat?
    private var isTemplate: Bool { image?.isTemplate ?? true }

    private static let plateOutset: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.cornerCurve = .continuous
        plate.isHidden = true
        layer?.addSublayer(plate)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let luminance, dark ? luminance < 0.22 : luminance > 0.92 {
            plate.isHidden = false
            plate.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.25, alpha: 0.9)).layerColor
        } else {
            plate.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds.insetBy(dx: -Self.plateOutset, dy: -Self.plateOutset)
        plate.cornerRadius = plate.frame.width * 0.25
        CATransaction.commit()
    }

    /// The average lightness of the pixels that show, or nil when none do.
    private static func luminance(of image: NSImage) -> CGFloat? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var light = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.1 else { continue }
            // Premultiplied, so each channel already carries the alpha.
            light += (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])) / 255
            weight += alpha
        }
        return weight > 0 ? CGFloat(light / weight) : nil
    }
}
