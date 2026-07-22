#!/usr/bin/env swift
import AppKit

// Renders Sich's checked-in brand artwork at every size macOS asks for.
// `make-app.sh` turns the resulting iconset into `Sich.icns` with `iconutil`.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sich.iconset"
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let defaultSourcePath = scriptURL
    .deletingLastPathComponent() // packaging
    .deletingLastPathComponent() // app
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("assets/sich-icon.png")
    .path
let sourcePath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : defaultSourcePath

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("error: could not load icon artwork at \(sourcePath)\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try FileManager.default.createDirectory(
        atPath: outDir,
        withIntermediateDirectories: true
    )
} catch {
    fputs("error: could not create iconset at \(outDir): \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

/// Render the icon at `size`×`size` into a PNG at `path`.
func renderIcon(size: Int, to path: String) {
    let dimensions = NSSize(width: size, height: size)
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

    bitmap.size = dimensions
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    let canvas = NSRect(origin: .zero, size: dimensions)
    let dimension = CGFloat(size)
    let iconInset = dimension * 0.08
    let iconRect = canvas.insetBy(dx: iconInset, dy: iconInset)
    let cornerRadius = dimension * 0.20
    let iconPath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // A macOS icon is not automatically masked like an iOS icon. Leave a real
    // transparent gutter around the artwork and provide the soft shadow inside
    // the canvas; otherwise an opaque source PNG is displayed as a white square.
    context.clear(canvas)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -dimension * 0.018),
        blur: dimension * 0.028,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    context.addPath(iconPath)
    context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // The checked-in artwork already contains a rounded tile plus a narrow
    // white export margin. Crop that margin, then clip it to the native icon
    // silhouette so none of the opaque corner canvas survives.
    let cropX = sourceImage.size.width * 0.018
    let cropY = sourceImage.size.height * 0.018
    let sourceRect = NSRect(
        x: cropX,
        y: cropY,
        width: sourceImage.size.width - cropX * 2,
        height: sourceImage.size.height - cropY * 2
    )
    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    graphicsContext.imageInterpolation = .high
    sourceImage.draw(
        in: iconRect,
        from: sourceRect,
        operation: .sourceOver,
        fraction: 1
    )
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("error: could not encode \(size)x\(size) icon PNG\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fputs("error: could not write \(path): \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
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
