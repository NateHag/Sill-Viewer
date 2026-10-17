import AppKit

/// The status item's image: design/AppIcon.svg reduced to a menu bar template. The iMac is an
/// outline with its stand, the iPad sits tilted in its screen as in the icon, and the state shows
/// on the iPad: empty (idle), a dot (a device is connected), a window (streaming), or a badge at
/// the lower right (Sill needs attention).
///
/// Drawn in code from the SVG's own coordinates, so there is no asset to keep in sync, and marked
/// as a template so the menu bar tints it for light and dark bars and highlights it when the menu
/// is open. `symbolFallback` (SF Symbol macbook.and.ipad) is the stand-in if this drawing is ever
/// dropped; the previews render both side by side.
enum StatusGlyph {
    enum State: Equatable, CaseIterable { case idle, connected, streaming, attention }

    /// 18 pt tall: 16 pt of drawing and a point above and below, like the system's own items.
    static let size = NSSize(width: 21, height: 18)

    static let symbolFallback: NSImage? = {
        let image = NSImage(systemSymbolName: "macbook.and.ipad", accessibilityDescription: "Sill")
        image?.isTemplate = true
        return image
    }()

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sill"
        return image
    }

    // MARK: Geometry, in AppIcon.svg units (1024 grid; the iMac group's 56-unit shift applied)

    /// Units → points: the drawing spans the iMac's 536-unit height (body top to foot bottom) in
    /// 16 pt, centred in the image.
    private static let scale: CGFloat = 16 / 536
    private static let origin = CGPoint(x: 176 - (size.width / scale - 672) / 2, y: 232 - 1 / scale)

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: (x - origin.x) * scale, y: (y - origin.y) * scale, width: w * scale, height: h * scale)
    }

    private static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil)
    }

    private static func draw(_ state: State, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)

        // The iMac: body outline (stroked inside the SVG's 672×456 rectangle), neck and foot.
        let stroke: CGFloat = 50                              // 1.5 pt
        ctx.setLineWidth(stroke * scale)
        ctx.addPath(rounded(rect(176 + stroke / 2, 232 + stroke / 2, 672 - stroke, 456 - stroke), 60 - stroke / 2))
        ctx.strokePath()
        ctx.fill(rect(480, 686, 64, 50))
        ctx.addPath(rounded(rect(372, 728, 280, 40), 20))
        ctx.fillPath()

        // The iPad, tilted -5° like the icon's, centred in the iMac's screen: an outline whose
        // screen shows the state.
        let center = rect(512, 460, 0, 0).origin
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -5 * .pi / 180)
        let pad = CGRect(x: -180 * scale, y: -125 * scale, width: 360 * scale, height: 250 * scale)
        let border: CGFloat = 40                              // 1.2 pt
        ctx.setLineWidth(border * scale)
        ctx.addPath(CGPath(roundedRect: pad.insetBy(dx: border / 2 * scale, dy: border / 2 * scale),
                           cornerWidth: 24 * scale, cornerHeight: 24 * scale, transform: nil))
        ctx.strokePath()
        switch state {
        case .connected:
            let d: CGFloat = 70 * scale
            ctx.fillEllipse(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
        case .streaming:
            let window = pad.insetBy(dx: (border + 30) * scale, dy: (border + 30) * scale)
            ctx.addPath(CGPath(roundedRect: window, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            ctx.fillPath()
        case .idle, .attention:
            break
        }
        ctx.restoreGState()

        // Attention: a dot at the lower right, cut out of whatever it overlaps.
        if state == .attention {
            let d = size.height * 0.42
            let dot = CGRect(x: size.width - d, y: size.height - d, width: d, height: d)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: dot)
        }
    }
}
