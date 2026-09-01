// Draws Resources/AppIcon.icns from scratch.
//
// Checking a binary .icns into a repo means nobody can see what changed when it
// changes. Generating it from ~100 lines of Core Graphics keeps the icon in
// source control as source.
//
//   swift Scripts/make-icon.swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

/// macOS icons sit in a squircle with a margin, not edge to edge.
func squircle(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.2237   // Apple's continuous-corner ratio
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// One fan blade, swept around the hub.
func blade(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let hub = radius * 0.17
    func point(_ a: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    path.move(to: point(angle - 0.34, hub))
    // Leading edge sweeps out and curls; trailing edge returns tight to the hub,
    // which is what reads as "fan" rather than "flower".
    path.addCurve(to: point(angle + 0.95, radius),
                  control1: point(angle - 0.30, radius * 0.72),
                  control2: point(angle + 0.30, radius * 1.02))
    path.addCurve(to: point(angle + 0.42, hub),
                  control1: point(angle + 1.28, radius * 0.80),
                  control2: point(angle + 1.05, hub * 1.9))
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let margin = size * 0.085
    let body = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)

    // Background: deep slate to teal, cool like the thing it measures.
    ctx.saveGState()
    ctx.addPath(squircle(in: body))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.11, green: 0.16, blue: 0.24, alpha: 1),
        CGColor(red: 0.06, green: 0.42, blue: 0.51, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])
    ctx.restoreGState()

    let center = CGPoint(x: body.midX, y: body.midY)
    let radius = body.width * 0.335

    // Ring: the gauge arc from the app, quoted on the icon.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(size * 0.028)
    ctx.addArc(center: center, radius: radius * 1.28,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Blades.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    for i in 0..<3 {
        let angle = CGFloat(i) * (.pi * 2 / 3) + 0.35
        ctx.addPath(blade(center: center, radius: radius, angle: angle))
        ctx.fillPath()
    }

    // Hub.
    ctx.setFillColor(CGColor(red: 0.06, green: 0.42, blue: 0.51, alpha: 1))
    ctx.addArc(center: center, radius: radius * 0.155,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.addArc(center: center, radius: radius * 0.075,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not create \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// iconutil expects this exact set of names.
for base in [16, 32, 128, 256, 512] {
    try write(drawIcon(size: CGFloat(base)),
              to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try write(drawIcon(size: CGFloat(base * 2)),
              to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(at: root.appendingPathComponent("Resources"),
                       withIntermediateDirectories: true)

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(1) }

// Keep one large PNG for the README, which cannot display .icns.
try write(drawIcon(size: 512), to: root.appendingPathComponent("docs/icon.png"))

print("wrote Resources/AppIcon.icns and docs/icon.png")
