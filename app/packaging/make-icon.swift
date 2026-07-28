#!/usr/bin/env swift
import AppKit

// Renders Sich's checked-in brand artwork at every size macOS asks for.
// `make-app.sh` turns the resulting iconset into `Sich.icns` with `iconutil`.
//
//   make-icon.swift [outDir] [sourcePng]           → a 10-PNG macOS iconset
//   make-icon.swift --flat <outPng> [size] [source] → one transparent PNG
//
// The `--flat` variant exists for surfaces that composite the icon themselves —
// README/GitHub, where the source artwork's opaque white export canvas renders
// as a white block (and worse in dark mode). It reuses the same crop-and-clip
// that keeps white out of the app icon, minus the macOS-only plate and shadow.

/// How the artwork is dressed for its destination.
enum IconStyle {
    /// macOS app icon: transparent gutter, drop shadow, light backing plate.
    case macOSApp
    /// Full-bleed rounded tile on transparency — no gutter, plate or shadow.
    case flat
}

var arguments = Array(CommandLine.arguments.dropFirst())
let style: IconStyle = arguments.first == "--flat" ? .flat : .macOSApp
if style == .flat { arguments.removeFirst() }

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryRoot = scriptURL
    .deletingLastPathComponent() // packaging
    .deletingLastPathComponent() // app
    .deletingLastPathComponent() // repository root
let defaultSourcePath = repositoryRoot.appendingPathComponent("assets/sich-icon.png").path

/// Positional arguments differ per style, so name them once here.
let outPath: String
let flatSize: Int
let sourcePath: String
switch style {
case .macOSApp:
    outPath = arguments.first ?? "Sich.iconset"
    flatSize = 0
    sourcePath = arguments.count > 1 ? arguments[1] : defaultSourcePath
case .flat:
    guard let destination = arguments.first else {
        fputs("usage: make-icon.swift --flat <outPng> [size] [sourcePng]\n", stderr)
        exit(EXIT_FAILURE)
    }
    outPath = destination
    flatSize = arguments.count > 1 ? (Int(arguments[1]) ?? 512) : 512
    sourcePath = arguments.count > 2 ? arguments[2] : defaultSourcePath
}

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("error: could not load icon artwork at \(sourcePath)\n", stderr)
    exit(EXIT_FAILURE)
}

// An iconset IS the output directory; a flat PNG only needs its parent to exist.
let outputDirectory = style == .macOSApp
    ? URL(fileURLWithPath: outPath)
    : URL(fileURLWithPath: outPath).deletingLastPathComponent()
do {
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )
} catch {
    fputs("error: could not create \(outputDirectory.path): \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

/// Allocate a straight-alpha RGBA canvas of `size`×`size` points.
func makeCanvas(size: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("error: could not allocate \(size)x\(size) icon bitmap\n", stderr)
        exit(EXIT_FAILURE)
    }
    bitmap.size = NSSize(width: size, height: size)
    return (bitmap, graphicsContext)
}

/// The rounded silhouette the artwork is clipped to, and the rect it fills.
func silhouette(in canvas: NSRect) -> (rect: NSRect, path: CGPath) {
    let dimension = canvas.width
    // The gutter is what makes a macOS icon sit inside its grid slot. A flat PNG
    // has no grid — inset there would just shrink the mark and reintroduce the
    // empty margin we are removing.
    let iconInset = style == .macOSApp ? dimension * 0.08 : 0
    let rect = canvas.insetBy(dx: iconInset, dy: iconInset)
    // Deliberately a fraction of the CANVAS, not of `rect`: the app icon's
    // silhouette is tuned against this radius, and rebasing it on the inset rect
    // would quietly reshape every existing icon size.
    let cornerRadius = dimension * 0.20
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    return (rect, path)
}

/// Fill the silhouette with the light backing plate and its drop shadow.
///
/// A macOS icon is not automatically masked like an iOS icon: it needs a real
/// transparent gutter and a shadow drawn inside its own canvas, or an opaque
/// source PNG shows up as a white square. The flat variant skips both — a baked
/// shadow and a near-white plate are wrong on any surface that supplies its own
/// background, and GitHub's dark mode would render them as a grey halo.
func drawPlate(in context: CGContext, path: CGPath, dimension: CGFloat) {
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -dimension * 0.018),
        blur: dimension * 0.028,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    context.addPath(path)
    context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
}

/// Draw the source artwork into `rect`, clipped to the icon silhouette.
///
/// The checked-in artwork already contains a rounded tile plus a narrow white
/// export margin. Crop that margin, then clip so none of the opaque corner
/// canvas survives.
func drawArtwork(in graphicsContext: NSGraphicsContext, rect: NSRect, path: CGPath) {
    let cropX = sourceImage.size.width * 0.018
    let cropY = sourceImage.size.height * 0.018
    let sourceRect = NSRect(
        x: cropX,
        y: cropY,
        width: sourceImage.size.width - cropX * 2,
        height: sourceImage.size.height - cropY * 2
    )
    let context = graphicsContext.cgContext
    context.saveGState()
    context.addPath(path)
    context.clip()
    graphicsContext.imageInterpolation = .high
    sourceImage.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
    context.restoreGState()
}

/// Encode `bitmap` as a PNG at `path`, or exit with a diagnostic.
func writePNG(_ bitmap: NSBitmapImageRep, to path: String) {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("error: could not encode icon PNG for \(path)\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fputs("error: could not write \(path): \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

/// Render the icon at `size`×`size` into a PNG at `path`.
func renderIcon(size: Int, to path: String) {
    let (bitmap, graphicsContext) = makeCanvas(size: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphicsContext

    let canvas = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let icon = silhouette(in: canvas)
    graphicsContext.cgContext.clear(canvas)
    if style == .macOSApp {
        drawPlate(in: graphicsContext.cgContext, path: icon.path, dimension: canvas.width)
    }
    drawArtwork(in: graphicsContext, rect: icon.rect, path: icon.path)
    writePNG(bitmap, to: path)
}

// macOS iconset sizes (1x + 2x for each nominal size).
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

switch style {
case .macOSApp:
    for spec in specs {
        renderIcon(size: spec.px, to: "\(outPath)/\(spec.name).png")
    }
    print("wrote \(specs.count) icon PNGs to \(outPath)")
case .flat:
    renderIcon(size: flatSize, to: outPath)
    print("wrote \(flatSize)x\(flatSize) transparent icon to \(outPath)")
}
