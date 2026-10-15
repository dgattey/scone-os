import AppKit
import CoreGraphics
import Foundation

enum IconAppearance {
    case dark
    case light
}

do {
    let root = repoRoot()
    let build = root.appending(path: "build", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let pixels = 1024

    guard let darkImage = render(size: pixels, appearance: .dark, applySquircle: true),
          let lightImage = render(size: pixels, appearance: .light, applySquircle: true),
          let iosDarkFullBleed = render(size: pixels, appearance: .dark, applySquircle: false),
          let iosLightFullBleed = render(size: pixels, appearance: .light, applySquircle: false) else {
        fputs("Could not draw the icon\n", stderr)
        exit(1)
    }

    let darkPreview = build.appending(path: "AppIcon-Dark-1024.png")
    let lightPreview = build.appending(path: "AppIcon-Light-1024.png")
    let defaultPreview = build.appending(path: "AppIcon-1024.png")

    guard let darkData = png(darkImage, size: pixels),
          let lightData = png(lightImage, size: pixels) else {
        fputs("Could not encode the icon\n", stderr)
        exit(1)
    }
    try darkData.write(to: darkPreview)
    try darkData.write(to: defaultPreview)
    try lightData.write(to: lightPreview)

    let xcassets = build.appending(path: "Assets.xcassets", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: xcassets)
    let appiconset = xcassets.appending(path: "AppIcon.appiconset", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)

    let rootContentsJSON = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try rootContentsJSON.write(
        to: xcassets.appending(path: "Contents.json"),
        atomically: true,
        encoding: .utf8
    )

    if let iosLightData = png(iosLightFullBleed, size: 1024),
       let iosDarkData = png(iosDarkFullBleed, size: 1024) {
        try iosLightData.write(to: appiconset.appending(path: "AppIcon-iOS-Light-1024.png"))
        try iosDarkData.write(to: appiconset.appending(path: "AppIcon-iOS-Dark-1024.png"))
    }
    try lightData.write(to: appiconset.appending(path: "AppIcon-macOS-Light-1024.png"))
    try darkData.write(to: appiconset.appending(path: "AppIcon-macOS-Dark-1024.png"))

    let appIconContentsJSON = """
    {
      "images" : [
        {
          "filename" : "AppIcon-iOS-Light-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "filename" : "AppIcon-iOS-Dark-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "filename" : "AppIcon-macOS-Dark-1024.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "512x512"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try appIconContentsJSON.write(
        to: appiconset.appending(path: "Contents.json"),
        atomically: true,
        encoding: .utf8
    )

    try buildIcns(
        image: darkImage,
        iconset: build.appending(path: "AppIcon.iconset", directoryHint: .isDirectory),
        output: build.appending(path: "AppIcon.icns")
    )
    try buildIcns(
        image: lightImage,
        iconset: build.appending(path: "AppIcon-Light.iconset", directoryHint: .isDirectory),
        output: build.appending(path: "AppIcon-Light.icns")
    )
    print(build.appending(path: "AppIcon.icns").path)
}

private func buildIcns(image: CGImage, iconset: URL, output: URL) throws {
    try? FileManager.default.removeItem(at: iconset)
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

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        fputs("iconutil exited \(task.terminationStatus)\n", stderr)
        exit(task.terminationStatus)
    }
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

private func render(size: Int, appearance: IconAppearance, applySquircle: Bool) -> CGImage? {
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
    drawIcon(ctx, CGFloat(size), appearance: appearance, applySquircle: applySquircle)
    return ctx.makeImage()
}

private func buildSmoothOscillatingWavePath(
    side: CGFloat,
    leftCapX: CGFloat,
    leftCapY: CGFloat,
    rightCapX: CGFloat,
    rightCapY: CGFloat,
    topExtrema: [(CGFloat, CGFloat)],
    bottomExtrema: [(CGFloat, CGFloat)]
) -> CGPath {
    let p = CGMutablePath()
    func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        CGPoint(x: side * nx, y: side * ny)
    }
    guard let firstTop = topExtrema.first,
          let lastTop = topExtrema.last,
          let firstBot = bottomExtrema.first,
          let lastBot = bottomExtrema.last else { return p }

    p.move(to: pt(leftCapX, leftCapY))
    let leftSpanX = firstTop.0 - leftCapX
    p.addCurve(
        to: pt(firstTop.0, firstTop.1),
        control1: pt(leftCapX, firstTop.1 + (leftCapY - firstTop.1) * 0.35),
        control2: pt(firstTop.0 - leftSpanX * 0.48, firstTop.1)
    )

    for i in 0..<(topExtrema.count - 1) {
        let a = topExtrema[i]
        let b = topExtrema[i + 1]
        let dx = (b.0 - a.0) * 0.50
        p.addCurve(
            to: pt(b.0, b.1),
            control1: pt(a.0 + dx, a.1),
            control2: pt(b.0 - dx, b.1)
        )
    }

    let rightTopSpanX = rightCapX - lastTop.0
    p.addCurve(
        to: pt(rightCapX, rightCapY),
        control1: pt(lastTop.0 + rightTopSpanX * 0.48, lastTop.1),
        control2: pt(rightCapX, lastTop.1 + (rightCapY - lastTop.1) * 0.35)
    )

    let rightBotSpanX = rightCapX - lastBot.0
    p.addCurve(
        to: pt(lastBot.0, lastBot.1),
        control1: pt(rightCapX, lastBot.1 - (lastBot.1 - rightCapY) * 0.35),
        control2: pt(lastBot.0 + rightBotSpanX * 0.48, lastBot.1)
    )

    for i in stride(from: bottomExtrema.count - 1, to: 0, by: -1) {
        let a = bottomExtrema[i]
        let b = bottomExtrema[i - 1]
        let dx = (a.0 - b.0) * 0.50
        p.addCurve(
            to: pt(b.0, b.1),
            control1: pt(a.0 - dx, a.1),
            control2: pt(b.0 + dx, b.1)
        )
    }

    let leftBotSpanX = firstBot.0 - leftCapX
    p.addCurve(
        to: pt(leftCapX, leftCapY),
        control1: pt(firstBot.0 - leftBotSpanX * 0.48, firstBot.1),
        control2: pt(leftCapX, firstBot.1 - (firstBot.1 - leftCapY) * 0.35)
    )
    p.closeSubpath()
    return p
}

private func drawIcon(_ ctx: CGContext, _ side: CGFloat, appearance: IconAppearance, applySquircle: Bool) {
    let dark = (appearance == .dark)
    let inset: CGFloat = applySquircle ? side * 0.096 : 0
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = applySquircle ? rect.width * 0.226 : 0
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if applySquircle {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: side * 0.022),
            blur: side * 0.045,
            color: rgb(0.0, 0.0, 0.0, dark ? 0.56 : 0.24)
        )
        ctx.addPath(squircle)
        ctx.setFillColor(dark ? rgb(0.07, 0.05, 0.04, 1.0) : rgb(0.95, 0.90, 0.82, 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors: CFArray = dark
        ? [rgb(0.135, 0.098, 0.072), rgb(0.062, 0.044, 0.032)] as CFArray
        : [rgb(0.985, 0.962, 0.922), rgb(0.935, 0.888, 0.808)] as CFArray

    if let bgGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: bgColors,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
    }

    if let glowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            rgb(0.98, 0.68, 0.24, dark ? 0.20 : 0.14),
            rgb(0.98, 0.68, 0.24, 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: side * 0.50, y: side * 0.50),
            startRadius: 0,
            endCenter: CGPoint(x: side * 0.50, y: side * 0.50),
            endRadius: side * 0.40,
            options: []
        )
    }

    // 5-crest symmetric oscillating harmonic scone-waveform (zero straight lines):
    // Oscillates both above and below the horizontal centerline in 5 smooth golden lobes.
    let topExtrema: [(CGFloat, CGFloat)] = [
        (0.23, 0.385),
        (0.298, 0.472),
        (0.365, 0.265),
        (0.432, 0.452),
        (0.50, 0.180),
        (0.568, 0.452),
        (0.635, 0.265),
        (0.702, 0.472),
        (0.77, 0.385),
    ]
    let bottomExtrema: [(CGFloat, CGFloat)] = [
        (0.23, 0.615),
        (0.298, 0.528),
        (0.365, 0.735),
        (0.432, 0.548),
        (0.50, 0.820),
        (0.568, 0.548),
        (0.635, 0.735),
        (0.702, 0.528),
        (0.77, 0.615),
    ]

    let wavePath = buildSmoothOscillatingWavePath(
        side: side,
        leftCapX: 0.165,
        leftCapY: 0.50,
        rightCapX: 0.835,
        rightCapY: 0.50,
        topExtrema: topExtrema,
        bottomExtrema: bottomExtrema
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: side * 0.018),
        blur: side * 0.038,
        color: rgb(0.0, 0.0, 0.0, dark ? 0.46 : 0.22)
    )
    ctx.addPath(wavePath)
    ctx.setFillColor(rgb(0.78, 0.41, 0.12, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(wavePath)
    ctx.clip()

    let baseGradColors: CFArray = dark
        ? [rgb(0.88, 0.52, 0.16), rgb(0.68, 0.33, 0.08)] as CFArray
        : [rgb(0.84, 0.48, 0.14), rgb(0.64, 0.30, 0.07)] as CFArray
    if let bGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: baseGradColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            bGrad,
            start: CGPoint(x: side * 0.5, y: side * 0.45),
            end: CGPoint(x: side * 0.5, y: side * 0.82),
            options: []
        )
    }

    // Upper honey-butter glaze crown bounded by a pure cubic-Bezier S-wave (zero straight lines)
    let glazeMask = CGMutablePath()
    glazeMask.move(to: CGPoint(x: side * 0.10, y: side * 0.53))
    glazeMask.addCurve(
        to: CGPoint(x: side * 0.50, y: side * 0.49),
        control1: CGPoint(x: side * 0.25, y: side * 0.44),
        control2: CGPoint(x: side * 0.36, y: side * 0.55)
    )
    glazeMask.addCurve(
        to: CGPoint(x: side * 0.90, y: side * 0.47),
        control1: CGPoint(x: side * 0.64, y: side * 0.43),
        control2: CGPoint(x: side * 0.76, y: side * 0.54)
    )
    glazeMask.addCurve(
        to: CGPoint(x: side * 0.50, y: side * 0.05),
        control1: CGPoint(x: side * 0.92, y: side * 0.15),
        control2: CGPoint(x: side * 0.72, y: side * 0.05)
    )
    glazeMask.addCurve(
        to: CGPoint(x: side * 0.10, y: side * 0.53),
        control1: CGPoint(x: side * 0.28, y: side * 0.05),
        control2: CGPoint(x: side * 0.08, y: side * 0.15)
    )
    glazeMask.closeSubpath()

    ctx.saveGState()
    ctx.addPath(glazeMask)
    ctx.clip()
    let glazeColors: CFArray = dark
        ? [rgb(1.0, 0.90, 0.50), rgb(0.95, 0.62, 0.18)] as CFArray
        : [rgb(0.98, 0.85, 0.40), rgb(0.91, 0.57, 0.16)] as CFArray
    if let gGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glazeColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gGrad,
            start: CGPoint(x: side * 0.5, y: side * 0.18),
            end: CGPoint(x: side * 0.5, y: side * 0.55),
            options: []
        )
    }
    ctx.restoreGState()

    let sCurve = CGMutablePath()
    sCurve.move(to: CGPoint(x: side * 0.16, y: side * 0.52))
    sCurve.addCurve(
        to: CGPoint(x: side * 0.50, y: side * 0.49),
        control1: CGPoint(x: side * 0.27, y: side * 0.45),
        control2: CGPoint(x: side * 0.37, y: side * 0.54)
    )
    sCurve.addCurve(
        to: CGPoint(x: side * 0.84, y: side * 0.48),
        control1: CGPoint(x: side * 0.63, y: side * 0.44),
        control2: CGPoint(x: side * 0.74, y: side * 0.53)
    )
    ctx.addPath(sCurve)
    ctx.setStrokeColor(rgb(1.0, 0.93, 0.72, 0.42))
    ctx.setLineWidth(side * 0.009)
    ctx.setLineCap(.round)
    ctx.strokePath()

    ctx.restoreGState()
    ctx.restoreGState()

    if applySquircle {
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(
            dark
                ? rgb(1.0, 0.90, 0.72, 0.26)
                : rgb(0.76, 0.58, 0.34, 0.32)
        )
        ctx.setLineWidth(side * 0.003)
        ctx.strokePath()
        ctx.restoreGState()
    }
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
