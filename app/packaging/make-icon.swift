#!/usr/bin/env swift
import AppKit

// Draws Ghostling's app icon — a friendly ghost on a rounded indigo→violet gradient,
// matching the board's dark, calm palette — and writes the full `.iconset` (every
// size macOS asks for). `make-app.sh` turns the iconset into `Ghostling.icns` with
// `iconutil`. Pure Core Graphics, no external asset needed, so the icon is
// reproducible from source.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Ghostling.iconset"
try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)

/// Render the icon at `size`×`size` into a PNG at `path`.
func renderIcon(size: Int, to path: String) {
    let dim = CGFloat(size)
    let image = NSImage(size: NSSize(width: dim, height: dim))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return }
    drawBackground(ctx, dim: dim)
    drawGhost(ctx, dim: dim)
    image.unlockFocus()
    writePNG(image, size: size, to: path)
}

/// A rounded-rect (macOS "squircle"-ish) filled with the brand gradient.
func drawBackground(_ ctx: CGContext, dim: CGFloat) {
    let inset = dim * 0.06
    let rect = CGRect(x: inset, y: inset, width: dim - inset * 2, height: dim - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: dim * 0.22, cornerHeight: dim * 0.22,
                      transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.30, green: 0.28, blue: 0.66, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.16, green: 0.14, blue: 0.34, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: dim),
                           end: CGPoint(x: dim, y: 0), options: [])
    ctx.restoreGState()
}

/// A simple ghost silhouette: a domed body with a scalloped hem and two eyes.
func drawGhost(_ ctx: CGContext, dim: CGFloat) {
    let w = dim * 0.46
    let h = dim * 0.54
    let cx = dim / 2
    let bottom = dim * 0.30
    let top = bottom + h
    let body = CGMutablePath()
    body.move(to: CGPoint(x: cx - w / 2, y: bottom))
    body.addLine(to: CGPoint(x: cx - w / 2, y: bottom + h * 0.55))
    body.addQuadCurve(to: CGPoint(x: cx + w / 2, y: bottom + h * 0.55),
                      control: CGPoint(x: cx, y: top + h * 0.30))
    body.addLine(to: CGPoint(x: cx + w / 2, y: bottom))
    // scalloped hem (three bumps)
    let bumps = 3
    let bw = w / CGFloat(bumps)
    for i in 0..<bumps {
        let x0 = cx + w / 2 - CGFloat(i) * bw
        body.addQuadCurve(to: CGPoint(x: x0 - bw, y: bottom),
                          control: CGPoint(x: x0 - bw / 2, y: bottom - h * 0.12))
    }
    body.closeSubpath()
    ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.99, alpha: 1).cgColor)
    ctx.addPath(body)
    ctx.fillPath()
    // eyes
    let eyeR = dim * 0.045
    let eyeY = bottom + h * 0.52
    ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.14, blue: 0.34, alpha: 1).cgColor)
    for dx in [-w * 0.20, w * 0.20] {
        ctx.fillEllipse(in: CGRect(x: cx + dx - eyeR, y: eyeY - eyeR,
                                   width: eyeR * 2, height: eyeR * 2))
    }
}

func writePNG(_ image: NSImage, size: Int, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// macOS iconset sizes (1x + 2x for each nominal size).
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    renderIcon(size: spec.px, to: "\(outDir)/\(spec.name).png")
}
print("wrote \(specs.count) icon PNGs to \(outDir)")
