import AppKit

/// A rounded capsule of glass around `contentView`. Liquid Glass on macOS 26
/// and later; before that, which has no NSGlassEffectView, a blurred material
/// clipped to the same corners with `tintColor`, or a faint fill, over it.
final class GlassView: NSView {
    /// The glass itself: an NSGlassEffectView, or the material that stands in.
    private let effect: NSView
    /// The wash of `tintColor` over the material, before macOS 26.
    private let tint = TintLayerView()

    var contentView: NSView? {
        didSet {
            if #available(macOS 26, *), let glass = effect as? NSGlassEffectView {
                glass.contentView = contentView
                return
            }
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(contentView)
            pin(contentView, to: effect)
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            if #available(macOS 26, *), let glass = effect as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            } else {
                effect.layer?.cornerRadius = cornerRadius
            }
        }
    }

    var tintColor: NSColor? {
        didSet {
            if #available(macOS 26, *), let glass = effect as? NSGlassEffectView {
                glass.tintColor = tintColor
            } else {
                tint.color = tintColor ?? .quaternarySystemFill
            }
        }
    }

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            effect = NSGlassEffectView()
        } else {
            let material = NSVisualEffectView()
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.cornerCurve = .continuous
            material.layer?.masksToBounds = true
            // The material alone blurs the titlebar into the same color, so
            // a faint fill shows the capsule when there is no tint.
            tint.color = .quaternarySystemFill
            tint.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(tint)
            effect = material
        }
        super.init(frame: frame)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        pin(effect, to: self)
        if tint.superview != nil { pin(tint, to: effect) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// A plain fill whose color is set in `updateLayer`, so it follows the
/// appearance.
private final class TintLayerView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color?.cgColor
    }
}
