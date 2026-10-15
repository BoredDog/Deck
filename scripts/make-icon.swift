// Draws the Deck logo: a lime squircle with a bold geometric "D".
// Usage: swift scripts/make-icon.swift <teal|midnight|moss|graphite|plum|lime|none>|plum|midnight> <out.png> [size]
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "black"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "icon.png")
let size = args.count > 3 ? Int(args[3])! : 1024

// Always a near-black square with a lime D. Only the small status dot changes: one per theme, plus lime ("none" = no dot).
let dots: [String: UInt32] = ["teal": 0x4fc9b8, "midnight": 0x6f86d6, "moss": 0xa8c95a, "graphite": 0xd4d4d4, "plum": 0xb08cf5, "lime": 0xc6ff3d]
let bg = rgb(0x0c0c0c), edge = rgb(0x262626), dColor = rgb(0xc6ff3d)
let dotColor = dots[variant].map(rgb)

let s = CGFloat(size) / 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)

// Apple's icon grid: 824pt body inside a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(bg)
ctx.setStrokeColor(edge)
ctx.setLineWidth(6)
ctx.drawPath(using: .fillStroke)

/// A D shape: square-ish on the left, a half circle on the right.
func dPath(_ r: CGRect, leftRadius: CGFloat) -> CGPath {
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
let inner = outer.insetBy(dx: 0, dy: stroke).offsetBy(dx: 0, dy: 0)
let counter = CGRect(x: outer.minX + stroke, y: inner.minY, width: outer.width - stroke * 1.9, height: inner.height)
ctx.addPath(dPath(outer, leftRadius: 28))
ctx.addPath(dPath(counter, leftRadius: 6))
ctx.setFillColor(dColor)
ctx.fillPath(using: .evenOdd)

if let dotColor {
    ctx.setFillColor(dotColor)
    ctx.fillEllipse(in: CGRect(x: 760, y: 238, width: 92, height: 92))
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
