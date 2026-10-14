import AppKit
import CoreGraphics
import Foundation

do {
        let root = repoRoot()
        let build = root.appending(path: "build", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let pixels = 1024
        guard let image = render(size: pixels) else {
            fputs("Could not draw the icon\n", stderr)
            exit(1)
        }
        let preview = build.appending(path: "AppIcon-1024.png")
        guard let previewData = png(image, size: pixels) else {
            fputs("Could not encode the icon\n", stderr)
            exit(1)
        }
        do {
            try previewData.write(to: preview)
        } catch {
            fputs("Could not write \(preview.path)\n", stderr)
            exit(1)
        }

        let iconset = build.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
        let icns = build.appending(path: "AppIcon.icns")
        try? FileManager.default.removeItem(at: iconset)
        do {
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            let sizes = [
                ("icon_16x16.png", 16),
                ("icon_16x16@2x.png", 32),
                ("icon_32x32.png", 32),
                ("icon_32x32@2x.png", 64),
                ("icon_128x128.png", 128),
                ("icon_128x128@2x.png", 256),
                ("icon_256x256.png", 256),
                ("icon_256x256@2x.png", 512),
                ("icon_512x512.png", 512),
                ("icon_512x512@2x.png", 1024),
            ]
            for (name, size) in sizes {
                guard let data = png(image, size: size) else {
                    fputs("Could not scale \(name)\n", stderr)
                    exit(1)
                }
                try data.write(to: iconset.appending(path: name))
            }
        } catch {
            fputs("Could not write the iconset\n", stderr)
            exit(1)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            fputs("iconutil failed to start\n", stderr)
            exit(1)
        }
        if task.terminationStatus != 0 {
            fputs("iconutil exited \(task.terminationStatus)\n", stderr)
            exit(task.terminationStatus)
        }
        try? FileManager.default.removeItem(at: iconset)
        print(icns.path)
}

private func repoRoot() -> URL {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: cwd.appending(path: "Package.swift").path) {
        return cwd
    }
    return cwd.deletingLastPathComponent()
}

private func render(size: Int) -> CGImage? {
    let width = size
    let height = size
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(ctx, CGFloat(size))
    return ctx.makeImage()
}

private func drawIcon(_ ctx: CGContext, _ side: CGFloat) {
    let inset = side * 0.02
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let colors = [rgb(0.035, 0.043, 0.063), rgb(0.067, 0.082, 0.125)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: side * 0.1, y: side * 0.05),
            end: CGPoint(x: side * 0.9, y: side * 0.95),
            options: [])
    }
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0.85, 0.61, 0.32, 0.55), rgb(0.91, 0.72, 0.43, 0)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: side * 0.5, y: side * 0.48),
            startRadius: side * 0.02,
            endCenter: CGPoint(x: side * 0.5, y: side * 0.48),
            endRadius: side * 0.42,
            options: [])
    }

    let center = CGPoint(x: side * 0.5, y: side * 0.5)
    let rings: [(CGFloat, CGFloat, CGFloat)] = [
        (0.145, 7.5, 0.95),
        (0.205, 5.5, 0.72),
        (0.268, 4.0, 0.48),
        (0.332, 3.0, 0.30),
        (0.398, 2.2, 0.16),
    ]
    for (index, ring) in rings.enumerated() {
        let radius = side * ring.0
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.setStrokeColor(index.isMultiple(of: 2) ? rgb(0.91, 0.72, 0.43, ring.2) : rgb(0.85, 0.61, 0.32, ring.2))
        if index < 2 {
            ctx.setShadow(offset: .zero, blur: side * 0.02, color: rgb(0.91, 0.72, 0.43, 0.65))
        } else {
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        ctx.setLineWidth(ring.1 * side / 1024)
        ctx.strokeEllipse(in: box)
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let prism = CGRect(x: side * 0.39, y: side * 0.30, width: side * 0.22, height: side * 0.40)
    let body = CGPath(roundedRect: prism, cornerWidth: prism.width / 2, cornerHeight: prism.width / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    if let glass = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0.93, 0.95, 0.98, 0.55), rgb(0.55, 0.58, 0.64, 0.28), rgb(0.16, 0.17, 0.20, 0.45)] as CFArray,
        locations: [0, 0.45, 1]
    ) {
        ctx.drawLinearGradient(
            glass,
            start: CGPoint(x: prism.minX, y: prism.minY),
            end: CGPoint(x: prism.maxX, y: prism.maxY),
            options: [])
    }
    ctx.setStrokeColor(rgb(0, 0, 0, 0.28))
    ctx.setLineWidth(max(1, side * 0.0014))
    var y = prism.minY + prism.height * 0.24
    while y < prism.maxY - prism.height * 0.12 {
        ctx.move(to: CGPoint(x: prism.minX, y: y))
        ctx.addLine(to: CGPoint(x: prism.maxX, y: y))
        y += max(2, side * 0.008)
    }
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(body)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.55))
    ctx.setLineWidth(max(1.5, side * 0.003))
    ctx.strokePath()

    let cap = CGRect(
        x: prism.minX + prism.width * 0.14,
        y: prism.minY + prism.height * 0.05,
        width: prism.width * 0.72,
        height: prism.width * 0.42)
    ctx.setFillColor(rgb(1, 1, 1, 0.28))
    ctx.fillEllipse(in: cap)
    ctx.setStrokeColor(rgb(0.09, 0.07, 0.05, 0.65))
    ctx.setLineWidth(max(1.5, side * 0.004))
    ctx.strokeEllipse(in: cap.insetBy(dx: prism.width * 0.08, dy: cap.height * 0.16))

    let ledRadius = side * 0.012
    let led = CGPoint(x: prism.midX, y: prism.maxY - prism.height * 0.12)
    ctx.setFillColor(rgb(0.91, 0.72, 0.43, 0.95))
    ctx.setShadow(offset: .zero, blur: side * 0.012, color: rgb(0.91, 0.72, 0.43, 0.9))
    ctx.fillEllipse(in: CGRect(x: led.x - ledRadius, y: led.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: side * 0.2, y: side * 0.08),
            end: CGPoint(x: side * 0.7, y: side * 0.28),
            options: [])
    }
    ctx.restoreGState()

    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(0.91, 0.72, 0.43, 0.35))
    ctx.setLineWidth(max(2, side * 0.004))
    ctx.strokePath()
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

private func png(_ image: CGImage, size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
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
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: size, height: size))
        .draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
