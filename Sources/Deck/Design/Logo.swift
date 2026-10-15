import AppKit

/// The Deck logo: near-black squircle, lime "D", and a small dot in the current theme color.
/// Same geometry as scripts/make-icon.swift (which makes the .icns at build time).
enum Logo {
    /// The D on a 1024 grid, with its counter (the hole) for even-odd filling.
    private static func dPath(scale s: CGFloat, origin: CGPoint = .zero) -> CGPath {
        func shape(_ r: CGRect, leftRadius: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let rr = r.height / 2
            p.move(to: CGPoint(x: r.minX + leftRadius, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX - rr, y: r.midY), radius: rr, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            p.addLine(to: CGPoint(x: r.minX + leftRadius, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: leftRadius)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: leftRadius)
            p.closeSubpath()
            return p
        }
        let outer = CGRect(x: 292, y: 262, width: 452, height: 500)
        let stroke: CGFloat = 128
        let counter = CGRect(x: outer.minX + stroke, y: outer.minY + stroke, width: outer.width - stroke * 1.9, height: outer.height - stroke * 2)
        let p = CGMutablePath()
        p.addPath(shape(outer, leftRadius: 28))
        p.addPath(shape(counter, leftRadius: 6))
        var t = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: s, y: s)
        return p.copy(using: &t) ?? p
    }

    /// Full app icon (Dock, alerts, notifications).
    static func appIcon(dot: NSColor?, size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 1024
            let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil))
            ctx.setFillColor(NSColor(srgbRed: 0.047, green: 0.047, blue: 0.047, alpha: 1).cgColor)
            ctx.setStrokeColor(NSColor(srgbRed: 0.149, green: 0.149, blue: 0.149, alpha: 1).cgColor)
            ctx.setLineWidth(6 * s)
            ctx.drawPath(using: .fillStroke)
            ctx.addPath(dPath(scale: s))
            ctx.setFillColor(NSColor(srgbRed: 0.776, green: 1, blue: 0.239, alpha: 1).cgColor)
            ctx.fillPath(using: .evenOdd)
            if let dot {
                ctx.setFillColor(dot.cgColor)
                ctx.fillEllipse(in: CGRect(x: 760 * s, y: 238 * s, width: 92 * s, height: 92 * s))
            }
            return true
        }
    }

    /// Menu bar icon: the D in the menu bar's own text color (so it works on light and dark bars) plus the theme dot.
    static func menuBar(dot: NSColor) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Fit the D's 452×500 box into the 18pt height with a little margin.
            let s: CGFloat = 15 / 500
            ctx.addPath(dPath(scale: s, origin: CGPoint(x: 1 - 292 * s, y: 1.5 - 262 * s)))
            ctx.setFillColor(NSColor.labelColor.cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setFillColor(dot.cgColor)
            ctx.fillEllipse(in: CGRect(x: 15, y: 1.5, width: 4, height: 4))
            return true
        }
        image.isTemplate = false
        return image
    }
}
