import Cocoa

/// Translucent capsule control for the Quick Look overlay.
final class FusionOpenButton: NSControl {

    private let effectView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "Fusion")
    private let iconView = NSImageView()

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 11
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        effectView.alphaValue = 0.92
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "arrow.up.forward.app",
                                 accessibilityDescription: "Open in Fusion")?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(iconView)

        label.stringValue = "Fusion"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)

        toolTip = "Open in Fusion"

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),

            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            effectView.animator().alphaValue = 1
            effectView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            effectView.animator().alphaValue = 0.92
            effectView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        effectView.alphaValue = 0.75
    }

    override func mouseUp(with event: NSEvent) {
        effectView.alphaValue = 0.92
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
