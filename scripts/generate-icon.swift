import AppKit
import CoreGraphics
import Foundation

enum IconAppearance {
    case light
    case dark
}

enum IconSurface {
    case macOSSquircle
    case fullBleed
    case iconComposerLayer(includeGlow: Bool)
}

do {
    let root = repoRoot()
    let build = root.appending(path: "build", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let pixels = 1024

    guard let lightImage = render(size: pixels, appearance: .light, surface: .macOSSquircle),
          let darkImage = render(size: pixels, appearance: .dark, surface: .macOSSquircle),
          let iosLightFullBleed = render(size: pixels, appearance: .light, surface: .fullBleed),
          let iosDarkFullBleed = render(size: pixels, appearance: .dark, surface: .fullBleed),
          let layerLight = render(size: pixels, appearance: .light, surface: .iconComposerLayer(includeGlow: true)),
          let layerDark = render(size: pixels, appearance: .dark, surface: .iconComposerLayer(includeGlow: true)),
          let layerTinted = render(size: pixels, appearance: .dark, surface: .iconComposerLayer(includeGlow: false)) else {
        fputs("Could not draw the Scone Cone icon\n", stderr)
        exit(1)
    }

    guard let lightData = png(lightImage, size: pixels),
          let darkData = png(darkImage, size: pixels),
          let iosLightData = png(iosLightFullBleed, size: pixels),
          let iosDarkData = png(iosDarkFullBleed, size: pixels),
          let layerLightData = png(layerLight, size: pixels),
          let layerDarkData = png(layerDark, size: pixels),
          let layerTintedData = png(layerTinted, size: pixels) else {
        fputs("Could not encode the Scone Cone icon PNGs\n", stderr)
        exit(1)
    }

    let lightPreview = build.appending(path: "AppIcon-Light-1024.png")
    let darkPreview = build.appending(path: "AppIcon-Dark-1024.png")
    let defaultPreview = build.appending(path: "AppIcon-1024.png")
    let iosLightPreview = build.appending(path: "icon-1024-light.png")
    let iosDarkPreview = build.appending(path: "icon-1024-dark.png")

    try lightData.write(to: lightPreview)
    try lightData.write(to: defaultPreview)
    try darkData.write(to: darkPreview)
    try iosLightData.write(to: iosLightPreview)
    try iosDarkData.write(to: iosDarkPreview)

    let serverPublicIcon = root.appending(path: "server/public/app-icon.png")
    if FileManager.default.fileExists(atPath: serverPublicIcon.deletingLastPathComponent().path) {
        try darkData.write(to: serverPublicIcon)
    }

    // 1. Write Icon Composer AppIcon.icon bundle (compiled by actool into multi-appearance Assets.car for macOS 26 & iOS 26)
    let iconBundle = build.appending(path: "AppIcon.icon", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: iconBundle)
    let iconAssets = iconBundle.appending(path: "Assets", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: iconAssets, withIntermediateDirectories: true)

    try layerLightData.write(to: iconAssets.appending(path: "scone-cone-light.png"))
    try layerDarkData.write(to: iconAssets.appending(path: "scone-cone-dark.png"))
    try layerTintedData.write(to: iconAssets.appending(path: "scone-cone-tinted.png"))

    let iconComposerJSON = """
    {
      "fill-specializations" : [
        {
          "value" : {
            "linear-gradient" : [
              "srgb:1.00000,0.98431,0.95294,1.00000",
              "srgb:0.93333,0.86667,0.75294,1.00000"
            ]
          }
        },
        {
          "appearance" : "dark",
          "value" : {
            "linear-gradient" : [
              "srgb:0.22745,0.16863,0.12157,1.00000",
              "srgb:0.07059,0.05098,0.03529,1.00000"
            ]
          }
        }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "image-name-specializations" : [
                {
                  "value" : "scone-cone-light.png"
                },
                {
                  "appearance" : "dark",
                  "value" : "scone-cone-dark.png"
                },
                {
                  "appearance" : "tinted",
                  "value" : "scone-cone-tinted.png"
                }
              ],
              "name" : "Scone Cone"
            }
          ],
          "name" : "Scone Cone"
        }
      ],
      "supported-platforms" : {
        "circles" : [
          "watchOS"
        ],
        "squares" : "shared"
      }
    }
    """
    try iconComposerJSON.write(
        to: iconBundle.appending(path: "icon.json"),
        atomically: true,
        encoding: .utf8
    )

    // 2. Write Assets.xcassets/AppIcon.appiconset with Light, Dark, and Tinted variants
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

    try iosLightData.write(to: appiconset.appending(path: "AppIcon-iOS-Light-1024.png"))
    try iosDarkData.write(to: appiconset.appending(path: "AppIcon-iOS-Dark-1024.png"))
    try iosDarkData.write(to: appiconset.appending(path: "AppIcon-iOS-Tinted-1024.png"))
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
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "tinted"
            }
          ],
          "filename" : "AppIcon-iOS-Tinted-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "filename" : "AppIcon-macOS-Light-1024.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "512x512"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
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

    // 3. Build multi-resolution .icns files directly rendered at each pixel size (16..1024) for maximum crispness
    try buildIcns(
        appearance: .light,
        iconset: build.appending(path: "AppIcon.iconset", directoryHint: .isDirectory),
        output: build.appending(path: "AppIcon.icns")
    )
    print(build.appending(path: "AppIcon.icns").path)
}

private func buildIcns(appearance: IconAppearance, iconset: URL, output: URL) throws {
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
        guard let image = render(size: size, appearance: appearance, surface: .macOSSquircle),
              let data = png(image, size: size) else {
            fputs("Could not render \(name)\n", stderr)
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

private func render(size: Int, appearance: IconAppearance, surface: IconSurface) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let scale = CGFloat(size) / 1024.0
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    drawSconeConeIcon(
        ctx,
        pixelScale: scale,
        smallSize: size <= 32,
        appearance: appearance,
        surface: surface
    )
    return ctx.makeImage()
}

private func squirclePath(
    x0: CGFloat = 100,
    y0: CGFloat = 100,
    size: CGFloat = 824,
    corner: CGFloat = 0.29,
    n: CGFloat = 3.3,
    steps: Int = 48
) -> CGPath {
    let r = size * corner
    let x1 = x0 + size
    let y1 = y0 + size
    let corners: [(CGFloat, CGFloat, CGFloat)] = [
        (x1 - r, y0 + r, -.pi / 2),
        (x1 - r, y1 - r, 0.0),
        (x0 + r, y1 - r, .pi / 2),
        (x0 + r, y0 + r, .pi),
    ]
    let path = CGMutablePath()
    var first = true
    for (cx, cy, a0) in corners {
        for i in 0...steps {
            let t = a0 + (.pi / 2) * CGFloat(i) / CGFloat(steps)
            let ct = cos(t)
            let st = sin(t)
            let px = cx + r * copysign(pow(abs(ct), 2.0 / n), ct)
            let py = cy + r * copysign(pow(abs(st), 2.0 / n), st)
            if first {
                path.move(to: CGPoint(x: px, y: py))
                first = false
            } else {
                path.addLine(to: CGPoint(x: px, y: py))
            }
        }
    }
    path.closeSubpath()
    return path
}

private func drawSconeConeIcon(
    _ ctx: CGContext,
    pixelScale: CGFloat,
    smallSize: Bool,
    appearance: IconAppearance,
    surface: IconSurface
) {
    let dark = (appearance == .dark)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    switch surface {
    case .macOSSquircle:
        let sq = squirclePath()

        // Outer squircle drop shadow (dx=0, dy=18, stdDeviation=22)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -18.0 * pixelScale),
            blur: 44.0 * pixelScale,
            color: rgb(0, 0, 0, dark ? 0.55 : 0.22)
        )
        ctx.addPath(sq)
        ctx.setFillColor(dark ? hex(0x120D09) : hex(0xEEDDC0))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(sq)
        ctx.clip()

        drawBackgroundAndGlow(
            ctx,
            colorSpace: colorSpace,
            rect: CGRect(x: 100, y: 100, width: 824, height: 824),
            dark: dark
        )
        drawSconeConeMotif(
            ctx,
            colorSpace: colorSpace,
            pixelScale: pixelScale,
            smallSize: smallSize,
            dark: dark
        )
        drawTopSheen(ctx, colorSpace: colorSpace, dark: dark)
        drawSquircleRim(ctx, colorSpace: colorSpace, squircle: sq, dark: dark)
        ctx.restoreGState()

    case .fullBleed:
        let fullRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let bgColors = (dark
            ? [hex(0x3A2B1F), hex(0x120D09)]
            : [hex(0xFFFBF3), hex(0xEEDDC0)]) as CFArray
        if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                bgGrad,
                start: CGPoint(x: fullRect.minX, y: fullRect.minY),
                end: CGPoint(x: fullRect.minX + fullRect.width * 0.35, y: fullRect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let bleedScale: CGFloat = 1024.0 / 824.0
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: bleedScale, y: bleedScale)
        ctx.translateBy(x: -512, y: -512)

        drawRadialGlow(ctx, colorSpace: colorSpace, dark: dark)
        drawSconeConeMotif(
            ctx,
            colorSpace: colorSpace,
            pixelScale: pixelScale * bleedScale,
            smallSize: smallSize,
            dark: dark
        )
        drawTopSheen(ctx, colorSpace: colorSpace, dark: dark)
        ctx.restoreGState()

    case .iconComposerLayer(let includeGlow):
        let bleedScale: CGFloat = 1024.0 / 824.0
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: bleedScale, y: bleedScale)
        ctx.translateBy(x: -512, y: -512)

        if includeGlow {
            drawRadialGlow(ctx, colorSpace: colorSpace, dark: dark)
        }
        drawSconeConeMotif(
            ctx,
            colorSpace: colorSpace,
            pixelScale: pixelScale * bleedScale,
            smallSize: smallSize,
            dark: dark
        )
        if includeGlow {
            drawTopSheen(ctx, colorSpace: colorSpace, dark: dark)
        }
        ctx.restoreGState()
    }
}

private func drawBackgroundAndGlow(
    _ ctx: CGContext,
    colorSpace: CGColorSpace,
    rect: CGRect,
    dark: Bool
) {
    let bgColors = (dark
        ? [hex(0x3A2B1F), hex(0x120D09)]
        : [hex(0xFFFBF3), hex(0xEEDDC0)]) as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    drawRadialGlow(ctx, colorSpace: colorSpace, dark: dark)
}

private func drawRadialGlow(_ ctx: CGContext, colorSpace: CGColorSpace, dark: Bool) {
    let glowColor = dark ? hex(0xE5A93C, alpha: 0.30) : hex(0xF2B24A, alpha: 0.22)
    let glowClear = dark ? hex(0xE5A93C, alpha: 0.0) : hex(0xF2B24A, alpha: 0.0)
    if let glowGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [glowColor, glowClear] as CFArray,
        locations: [0.0, 1.0]
    ) {
        let center = CGPoint(x: 512, y: 540)
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: 400,
            options: []
        )
    }
}

private func drawTopSheen(_ ctx: CGContext, colorSpace: CGColorSpace, dark: Bool) {
    let sheenAlpha: CGFloat = dark ? 0.10 : 0.30
    let sheenPath = CGPath(
        ellipseIn: CGRect(x: 512 - 470, y: 150 - 260, width: 940, height: 520),
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(sheenPath)
    ctx.clip()
    if let sheenGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(1, 1, 1, sheenAlpha), rgb(1, 1, 1, 0)] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            sheenGrad,
            start: CGPoint(x: 512, y: 150 - 260),
            end: CGPoint(x: 512, y: 150 + 260),
            options: []
        )
    }
    ctx.restoreGState()
}

private func drawSquircleRim(
    _ ctx: CGContext,
    colorSpace: CGColorSpace,
    squircle: CGPath,
    dark: Bool
) {
    let strokedRim = squircle.copy(
        strokingWithWidth: 10,
        lineCap: .butt,
        lineJoin: .round,
        miterLimit: 10
    )
    let rimLowHex = dark ? 0xE5A93C : 0xC9A273
    let rimColors = [
        rgb(1, 1, 1, dark ? 0.32 : 0.85),
        rgb(1, 1, 1, 0.0),
        hex(rimLowHex, alpha: 0.0),
        hex(rimLowHex, alpha: dark ? 0.35 : 0.45),
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.45, 0.80, 1.0]

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(strokedRim)
    ctx.clip()
    if let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: locations) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: 100 + 824 * 0.2, y: 100),
            end: CGPoint(x: 100 + 824 * 0.8, y: 924),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()
}

private func makeWedgePath(ax: CGFloat, cy: CGFloat, radius: CGFloat, halfAngle: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: ax, y: cy))
    p.addLine(to: CGPoint(x: ax + radius * cos(-halfAngle), y: cy + radius * sin(-halfAngle)))
    p.addArc(
        center: CGPoint(x: ax, y: cy),
        radius: radius,
        startAngle: -halfAngle,
        endAngle: halfAngle,
        clockwise: false
    )
    p.closeSubpath()
    return p
}

private func makeArcPath(ax: CGFloat, cy: CGFloat, radius: CGFloat, halfAngle: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addArc(
        center: CGPoint(x: ax, y: cy),
        radius: radius,
        startAngle: -halfAngle,
        endAngle: halfAngle,
        clockwise: false
    )
    return p
}

private func drawSconeConeMotif(
    _ ctx: CGContext,
    colorSpace: CGColorSpace,
    pixelScale: CGFloat,
    smallSize: Bool,
    dark: Bool
) {
    let ax: CGFloat = 296
    let ay: CGFloat = 478
    let thick: CGFloat = 66
    let half: CGFloat = 36.0 * .pi / 180.0
    let R: CGFloat = 232
    let acy: CGFloat = ay + thick / 2.0

    let objShadowColor = dark ? rgb(0, 0, 0, 0.55) : hex(0x5A3210, alpha: 0.30)
    let objShadowOffset = CGSize(width: 0, height: -16.0 * pixelScale)
    let objShadowBlur: CGFloat = 32.0 * pixelScale

    // 1. Dark mode ambient golden sound-arc glow
    if dark {
        for (r, alpha) in [(CGFloat(336), CGFloat(0.80)), (CGFloat(432), CGFloat(0.48))] {
            let arcPath = makeArcPath(ax: ax, cy: acy, radius: r, halfAngle: half)
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 52.0 * pixelScale,
                color: hex(0xE5A93C, alpha: alpha)
            )
            ctx.addPath(arcPath)
            ctx.setStrokeColor(hex(0xE5A93C, alpha: alpha * 0.45))
            ctx.setLineWidth(60)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // 2. Honey-glass sound arcs (outer r=432, inner r=336)
    let arcStrokeWidth: CGFloat = smallSize ? 54 : 50
    let arcGradColors = (dark
        ? [hex(0xFFE08F), hex(0xE0892A)]
        : [hex(0xF4BC5A), hex(0xB8641A)]) as CFArray
    let arcSpecs: [(CGFloat, CGFloat)] = [
        (432, dark ? 0.60 : 0.82),
        (336, dark ? 0.95 : 1.00),
    ]

    for (r, op) in arcSpecs {
        let arcPath = makeArcPath(ax: ax, cy: acy, radius: r, halfAngle: half)
        let strokedArc = arcPath.copy(
            strokingWithWidth: arcStrokeWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )

        ctx.saveGState()
        ctx.setAlpha(op)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Drop shadow + base fill for the arc
        ctx.saveGState()
        ctx.setShadow(offset: objShadowOffset, blur: objShadowBlur, color: objShadowColor)
        ctx.addPath(strokedArc)
        ctx.setFillColor(dark ? hex(0xE0892A) : hex(0xB8641A))
        ctx.fillPath()
        ctx.restoreGState()

        // Vertical honey-glass gradient inside the stroked arc
        ctx.saveGState()
        ctx.addPath(strokedArc)
        ctx.clip()
        if let arcGrad = CGGradient(colorsSpace: colorSpace, colors: arcGradColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                arcGrad,
                start: CGPoint(x: ax + r, y: 250),
                end: CGPoint(x: ax + r, y: 790),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        // Crisp white specular highlight along outer edge (r + 12)
        let specPath = makeArcPath(ax: ax, cy: acy, radius: r + 12, halfAngle: half)
        ctx.saveGState()
        ctx.addPath(specPath)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.60))
        ctx.setLineWidth(smallSize ? 8.5 : 7.0)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // 3. Scone 3D biscuit side extrusion (dy from 66 down to 3 by -3) with object drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: objShadowOffset, blur: objShadowBlur, color: objShadowColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for dy in stride(from: Int(thick), to: 0, by: -3) {
        let t = pow(CGFloat(dy) / thick, 1.6)
        let col = lerpColor(0xF7DCA6, 0xA35616, t: t)
        let layerWedge = makeWedgePath(ax: ax, cy: ay + CGFloat(dy), radius: R, halfAngle: half)
        ctx.addPath(layerWedge)
        ctx.setFillColor(col)
        ctx.setStrokeColor(col)
        ctx.setLineWidth(40)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 4. Flaky biscuit seam at dy = 30
    if !smallSize {
        let flakeWedge = makeWedgePath(ax: ax, cy: ay + 30, radius: R, halfAngle: half)
        ctx.saveGState()
        ctx.addPath(flakeWedge)
        ctx.setStrokeColor(hex(0xFFF2D2, alpha: 0.35))
        ctx.setLineWidth(5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 5. Scone top crust (filled + 40px round-joined stroke) with radial bake gradient, gloss, and sugar crystals
    let topWedge = makeWedgePath(ax: ax, cy: ay, radius: R, halfAngle: half)
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Establish alpha mask of the filled + 40px round-stroked wedge
    ctx.addPath(topWedge)
    ctx.setFillColor(rgb(1, 1, 1, 1))
    ctx.setStrokeColor(rgb(1, 1, 1, 1))
    ctx.setLineWidth(40)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)

    // Fill alpha mask with c2Top radial gradient (.sourceIn)
    ctx.setBlendMode(.sourceIn)
    let topColors = (dark
        ? [hex(0xFFCF7C), hex(0xE09434), hex(0xA9591A)]
        : [hex(0xF5BE62), hex(0xD7882C), hex(0xA9591A)]) as CFArray
    let topLocations: [CGFloat] = [0.0, 0.6, 1.0]
    if let topGrad = CGGradient(colorsSpace: colorSpace, colors: topColors, locations: topLocations) {
        let gradCenter = CGPoint(x: ax + 90, y: ay - 50)
        ctx.drawRadialGradient(
            topGrad,
            startCenter: gradCenter,
            startRadius: 0,
            endCenter: gradCenter,
            endRadius: 280,
            options: [.drawsAfterEndLocation]
        )
    }

    // Draw honey-butter gloss ellipse and coarse sugar crystals clipped to the top wedge (.sourceAtop)
    ctx.setBlendMode(.sourceAtop)
    ctx.saveGState()
    let glossCenter = CGPoint(x: ax + 110, y: ay - 60)
    let glossEllipse = CGPath(
        ellipseIn: CGRect(x: glossCenter.x - 150, y: glossCenter.y - 90, width: 300, height: 180),
        transform: nil
    )
    ctx.addPath(glossEllipse)
    ctx.clip()
    if let glossGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [hex(0xFFF6DC, alpha: 0.85), hex(0xFFF6DC, alpha: 0.0)] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            glossGrad,
            startCenter: glossCenter,
            startRadius: 0,
            endCenter: glossCenter,
            endRadius: 120,
            options: []
        )
    }
    ctx.restoreGState()

    if !smallSize {
        let sugars: [(CGFloat, CGFloat, CGFloat)] = [
            (392, 430, 20),
            (446, 404, 50),
            (430, 488, 10),
            (498, 452, 35),
            (372, 520, 70),
            (492, 530, 25),
            (462, 566, 60),
            (352, 470, 15),
            (500, 386, 5),
            (410, 560, 40),
        ]
        ctx.setFillColor(hex(0xFFFDF6, alpha: 0.92))
        for (sx, sy, deg) in sugars {
            ctx.saveGState()
            ctx.translateBy(x: sx, y: sy)
            ctx.rotate(by: deg * .pi / 180.0)
            let crystal = CGPath(
                roundedRect: CGRect(x: -6, y: -6, width: 12, height: 12),
                cornerWidth: 3,
                cornerHeight: 3,
                transform: nil
            )
            ctx.addPath(crystal)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

private func hex(_ value: Int, alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return rgb(r, g, b, alpha)
}

private func lerpColor(_ c0: Int, _ c1: Int, t: CGFloat) -> CGColor {
    let r0 = CGFloat((c0 >> 16) & 0xFF) / 255.0
    let g0 = CGFloat((c0 >> 8) & 0xFF) / 255.0
    let b0 = CGFloat(c0 & 0xFF) / 255.0
    let r1 = CGFloat((c1 >> 16) & 0xFF) / 255.0
    let g1 = CGFloat((c1 >> 8) & 0xFF) / 255.0
    let b1 = CGFloat(c1 & 0xFF) / 255.0
    return rgb(
        r0 + (r1 - r0) * t,
        g0 + (g1 - g0) * t,
        b0 + (b1 - b0) * t,
        1.0
    )
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGColor(colorSpace: space, components: [r, g, b, a]) ?? CGColor(red: r, green: g, blue: b, alpha: a)
}

private func png(_ image: CGImage, size: Int) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}
