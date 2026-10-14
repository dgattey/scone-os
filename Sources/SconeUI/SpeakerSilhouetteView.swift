import SwiftUI
import SconeDomain

struct SpeakerSilhouetteView: View {
    var model: SpeakerModel
    var isOnline: Bool
    var isPlaying: Bool = false
    var isGrouped: Bool = false
    var size: CGFloat = 72

    private var beam: Bool {
        if case .beamHt = model { true } else { false }
    }

    var body: some View {
        let model = model
        let online = isOnline
        let playing = isPlaying
        let side = size
        ZStack {
            aura
            Canvas { context, canvasSize in
                drawSpeaker(model, online: online, playing: playing, context: &context, size: canvasSize)
            }
            .frame(width: side, height: side)
            if case .move(let battery?) = model {
                batteryBadge(battery)
            }
        }
        .frame(width: side, height: side)
        .saturation(isOnline ? 1 : 0.15)
        .opacity(isOnline ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    private var auraHot: Bool { isPlaying || isGrouped }

    private var aura: some View {
        ZStack {
            auraFill
            auraStroke
        }
    }

    @ViewBuilder private var auraFill: some View {
        let tint = auraHot ? 0.34 : 0.16
        if beam {
            Capsule()
                .fill(MidnightGlass.copper.opacity(tint))
                .padding(.horizontal, size * 0.08)
                .padding(.vertical, size * 0.3)
                .blur(radius: auraHot ? 8 : 4)
        } else {
            Circle()
                .fill(MidnightGlass.copper.opacity(tint))
                .padding(size * 0.06)
                .blur(radius: auraHot ? 8 : 4)
        }
    }

    @ViewBuilder private var auraStroke: some View {
        let tint = auraHot ? 0.95 : 0.34
        let line = auraHot ? 2.0 : 1.0
        let colors = [MidnightGlass.gold.opacity(tint), MidnightGlass.copper.opacity(tint * 0.7)]
        if beam {
            Capsule()
                .stroke(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: line)
                .padding(.horizontal, size * 0.1)
                .padding(.vertical, size * 0.32)
        } else {
            Circle()
                .stroke(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: line)
                .padding(size * 0.08)
        }
    }

    private func batteryBadge(_ battery: BatteryTelemetry) -> some View {
        HStack(spacing: 2) {
            Text("\(battery.levelPercent)%")
            if battery.isOnCharger {
                Image(systemName: "bolt.fill")
            }
        }
        .font(.system(size: max(7, size * 0.11), weight: .semibold, design: .rounded))
        .foregroundStyle(MidnightGlass.gold)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(MidnightGlass.gold.opacity(0.65), lineWidth: 0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, size * 0.02)
    }
}

private func drawSpeaker(
    _ model: SpeakerModel,
    online: Bool,
    playing: Bool,
    context: inout GraphicsContext,
    size: CGSize
) {
    switch model {
    case .era100:
        drawPillar(context: &context, in: box(0.26, 0.08, 0.48, 0.84, size), colors: silver, playing: playing, online: online, groove: true)
    case .era300:
        drawEra300(context: &context, size: size, playing: playing, online: online)
    case .symfoniskBookshelf:
        drawBookshelf(context: &context, size: size, playing: playing, online: online)
    case .beamHt(let satellites):
        drawBeam(context: &context, size: size, playing: playing, online: online, satellites: !satellites.isEmpty)
    case .move:
        drawMove(context: &context, size: size, playing: playing, online: online)
    case .unrecognized:
        drawMonolith(context: &context, size: size, playing: playing, online: online)
    }
}

private let silver = [
    Color(red: 0.88, green: 0.90, blue: 0.93),
    Color(red: 0.62, green: 0.65, blue: 0.70),
    Color(red: 0.30, green: 0.32, blue: 0.36),
]
private let graphite = [
    Color(red: 0.28, green: 0.29, blue: 0.32),
    Color(red: 0.12, green: 0.13, blue: 0.15),
    Color(red: 0.22, green: 0.23, blue: 0.26),
]

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ size: CGSize) -> CGRect {
    CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
}

private func shading(_ colors: [Color], from start: CGPoint, to end: CGPoint) -> GraphicsContext.Shading {
    .linearGradient(Gradient(colors: colors), startPoint: start, endPoint: end)
}

private func floorShadow(_ context: inout GraphicsContext, under body: CGRect) {
    let shadow = CGRect(
        x: body.midX - body.width * 0.42,
        y: body.maxY - 1,
        width: body.width * 0.84,
        height: max(4, body.height * 0.05))
    context.fill(Path(ellipseIn: shadow), with: .color(Color.black.opacity(0.4)))
}

private func grille(_ context: inout GraphicsContext, in rect: CGRect, horizontal: Bool, step: CGFloat) {
    var path = Path()
    if horizontal {
        var y = rect.minY
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
    } else {
        var x = rect.minX
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
    }
    context.stroke(path, with: .color(Color.black.opacity(0.3)), lineWidth: max(0.4, step * 0.22))
}

private func led(_ context: inout GraphicsContext, at center: CGPoint, playing: Bool, online: Bool, scale: CGFloat) {
    let radius = max(1.5, scale * 0.055)
    let color: Color = if !online {
        Color.white.opacity(0.35)
    } else if playing {
        MidnightGlass.gold
    } else {
        Color(red: 0.45, green: 0.82, blue: 0.58)
    }
    let glow = CGRect(x: center.x - radius * 2.4, y: center.y - radius * 2.4, width: radius * 4.8, height: radius * 4.8)
    context.fill(
        Path(ellipseIn: glow),
        with: .radialGradient(
            Gradient(colors: [color.opacity(0.95), color.opacity(0)]),
            center: center,
            startRadius: 0,
            endRadius: radius * 2.6))
    let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.fill(Path(ellipseIn: dot), with: .color(color))
}

private func drawPillar(
    context: inout GraphicsContext,
    in body: CGRect,
    colors: [Color],
    playing: Bool,
    online: Bool,
    groove: Bool
) {
    floorShadow(&context, under: body)
    let path = Path(roundedRect: body, cornerRadius: body.width / 2)
    context.drawLayer { layer in
        layer.clip(to: path)
        layer.fill(
            path,
            with: shading(colors, from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY)))
        let mesh = CGRect(x: body.minX, y: body.minY + body.height * 0.22, width: body.width, height: body.height * 0.64)
        layer.clip(to: Path(mesh))
        grille(&layer, in: mesh, horizontal: true, step: max(1.7, body.height * 0.035))
    }
    context.stroke(path, with: .color(Color.white.opacity(0.34)), lineWidth: max(0.8, body.width * 0.02))
    if groove {
        let cap = CGRect(
            x: body.minX + body.width * 0.12,
            y: body.minY + body.height * 0.035,
            width: body.width * 0.76,
            height: body.width * 0.46)
        context.fill(
            Path(ellipseIn: cap),
            with: shading(
                [Color.white.opacity(0.72), colors[0].opacity(0.15)],
                from: CGPoint(x: cap.midX, y: cap.minY),
                to: CGPoint(x: cap.midX, y: cap.maxY)))
        let grooveRect = cap.insetBy(dx: body.width * 0.08, dy: cap.height * 0.18)
        context.stroke(
            Path(ellipseIn: grooveRect),
            with: .color(Color.black.opacity(0.55)),
            lineWidth: max(0.8, body.width * 0.04))
    }
    var streak = Path()
    streak.move(to: CGPoint(x: body.minX + body.width * 0.22, y: body.minY + body.height * 0.28))
    streak.addLine(to: CGPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.14))
    context.stroke(streak, with: .color(Color.white.opacity(0.4)), lineWidth: max(0.7, body.width * 0.03))
    led(
        &context,
        at: CGPoint(x: body.midX, y: body.maxY - body.height * 0.11),
        playing: playing,
        online: online,
        scale: body.width)
}

private func drawEra300(context: inout GraphicsContext, size: CGSize, playing: Bool, online: Bool) {
    let rect = box(0.16, 0.05, 0.68, 0.90, size)
    floorShadow(&context, under: rect)
    let path = hourglass(in: rect)
    context.drawLayer { layer in
        layer.clip(to: path)
        layer.fill(
            path,
            with: shading(silver, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY)))
        let mesh = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.55, width: rect.width, height: rect.height * 0.38)
        layer.clip(to: Path(mesh))
        grille(&layer, in: mesh, horizontal: true, step: max(1.6, rect.height * 0.028))
    }
    context.stroke(path, with: .color(Color.white.opacity(0.32)), lineWidth: 1)
    let driver = CGRect(
        x: rect.midX - rect.width * 0.14,
        y: rect.minY + rect.height * 0.64,
        width: rect.width * 0.28,
        height: rect.height * 0.14)
    context.stroke(Path(ellipseIn: driver), with: .color(Color.black.opacity(0.45)), lineWidth: 1.2)
    context.fill(Path(ellipseIn: driver.insetBy(dx: 3, dy: 2)), with: .color(Color.white.opacity(0.18)))
    waveGuide(&context, at: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.24), angle: .degrees(-52), length: rect.width * 0.28)
    waveGuide(&context, at: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.24), angle: .degrees(128), length: rect.width * 0.28)
    led(&context, at: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.08), playing: playing, online: online, scale: rect.width * 0.4)
}

private func hourglass(in rect: CGRect) -> Path {
    let w = rect.width
    let h = rect.height
    let top = rect.minY
    let cx = rect.midX
    var path = Path()
    path.move(to: CGPoint(x: cx, y: top + h * 0.02))
    path.addCurve(
        to: CGPoint(x: cx + w * 0.34, y: top + h * 0.15),
        control1: CGPoint(x: cx + w * 0.24, y: top),
        control2: CGPoint(x: cx + w * 0.40, y: top + h * 0.05))
    path.addCurve(
        to: CGPoint(x: cx + w * 0.10, y: top + h * 0.47),
        control1: CGPoint(x: cx + w * 0.28, y: top + h * 0.27),
        control2: CGPoint(x: cx + w * 0.14, y: top + h * 0.38))
    path.addCurve(
        to: CGPoint(x: cx + w * 0.40, y: top + h * 0.78),
        control1: CGPoint(x: cx + w * 0.06, y: top + h * 0.57),
        control2: CGPoint(x: cx + w * 0.42, y: top + h * 0.64))
    path.addCurve(
        to: CGPoint(x: cx, y: top + h * 0.98),
        control1: CGPoint(x: cx + w * 0.38, y: top + h * 0.92),
        control2: CGPoint(x: cx + w * 0.20, y: top + h))
    path.addCurve(
        to: CGPoint(x: cx - w * 0.40, y: top + h * 0.78),
        control1: CGPoint(x: cx - w * 0.20, y: top + h),
        control2: CGPoint(x: cx - w * 0.38, y: top + h * 0.92))
    path.addCurve(
        to: CGPoint(x: cx - w * 0.10, y: top + h * 0.47),
        control1: CGPoint(x: cx - w * 0.42, y: top + h * 0.64),
        control2: CGPoint(x: cx - w * 0.06, y: top + h * 0.57))
    path.addCurve(
        to: CGPoint(x: cx - w * 0.34, y: top + h * 0.15),
        control1: CGPoint(x: cx - w * 0.14, y: top + h * 0.38),
        control2: CGPoint(x: cx - w * 0.28, y: top + h * 0.27))
    path.addCurve(
        to: CGPoint(x: cx, y: top + h * 0.02),
        control1: CGPoint(x: cx - w * 0.40, y: top + h * 0.05),
        control2: CGPoint(x: cx - w * 0.24, y: top))
    path.closeSubpath()
    return path
}

private func waveGuide(_ context: inout GraphicsContext, at origin: CGPoint, angle: Angle, length: CGFloat) {
    context.drawLayer { layer in
        layer.translateBy(x: origin.x, y: origin.y)
        layer.rotate(by: angle)
        let slot = CGRect(x: 0, y: -4, width: length, height: 8)
        layer.stroke(Path(roundedRect: slot, cornerRadius: 4), with: .color(Color.black.opacity(0.55)), lineWidth: 2)
        layer.stroke(
            Path(roundedRect: slot.insetBy(dx: 1.4, dy: 1.4), cornerRadius: 3),
            with: .color(MidnightGlass.copper.opacity(0.95)),
            lineWidth: 1)
    }
}

private func drawBookshelf(context: inout GraphicsContext, size: CGSize, playing: Bool, online: Bool) {
    let outer = box(0.20, 0.05, 0.60, 0.90, size)
    floorShadow(&context, under: outer)
    let frame = Path(roundedRect: outer, cornerRadius: size.width * 0.045)
    context.fill(
        frame,
        with: shading(
            [Color(red: 0.34, green: 0.30, blue: 0.26), Color(red: 0.14, green: 0.12, blue: 0.11)],
            from: CGPoint(x: outer.minX, y: outer.minY),
            to: CGPoint(x: outer.maxX, y: outer.maxY)))
    let panel = outer.insetBy(dx: outer.width * 0.12, dy: outer.height * 0.045)
    let upper = CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height * 0.48)
    let lower = CGRect(x: panel.minX, y: upper.maxY, width: panel.width, height: panel.height - upper.height)
    context.drawLayer { layer in
        layer.clip(to: Path(roundedRect: panel, cornerRadius: 3))
        layer.fill(Path(upper), with: .color(Color(red: 0.66, green: 0.63, blue: 0.58)))
        layer.fill(Path(lower), with: .color(Color(red: 0.30, green: 0.28, blue: 0.26)))
        grille(&layer, in: panel, horizontal: false, step: max(2.2, panel.width * 0.08))
    }
    context.stroke(frame, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
    var edge = Path()
    edge.move(to: CGPoint(x: outer.minX + outer.width * 0.08, y: outer.minY + 8))
    edge.addLine(to: CGPoint(x: outer.minX + outer.width * 0.08, y: outer.maxY - 8))
    context.stroke(edge, with: .color(Color.white.opacity(0.28)), lineWidth: 1.2)
    led(&context, at: CGPoint(x: outer.midX, y: outer.maxY - outer.height * 0.035), playing: playing, online: online, scale: outer.width * 0.35)
}

private func drawBeam(
    context: inout GraphicsContext,
    size: CGSize,
    playing: Bool,
    online: Bool,
    satellites: Bool
) {
    let bar = box(satellites ? 0.16 : 0.05, satellites ? 0.20 : 0.34, satellites ? 0.68 : 0.90, 0.30, size)
    floorShadow(&context, under: bar.insetBy(dx: -8, dy: 0))
    let path = Path(roundedRect: bar, cornerRadius: bar.height / 2)
    context.drawLayer { layer in
        layer.clip(to: path)
        layer.fill(
            path,
            with: shading(graphite, from: CGPoint(x: bar.minX, y: bar.minY), to: CGPoint(x: bar.maxX, y: bar.maxY)))
        let mesh = bar.insetBy(dx: bar.height * 0.45, dy: bar.height * 0.28)
        grille(&layer, in: mesh, horizontal: true, step: max(1.5, bar.height * 0.16))
    }
    context.stroke(path, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
    var top = Path()
    top.move(to: CGPoint(x: bar.minX + bar.height * 0.6, y: bar.minY + bar.height * 0.22))
    top.addLine(to: CGPoint(x: bar.maxX - bar.height * 0.6, y: bar.minY + bar.height * 0.22))
    context.stroke(top, with: .color(Color.white.opacity(0.35)), lineWidth: 1)
    led(&context, at: CGPoint(x: bar.midX, y: bar.midY), playing: playing, online: online, scale: bar.height * 0.7)
    if satellites {
        let sat = CGSize(width: size.width * 0.13, height: size.height * 0.26)
        let y = bar.maxY + size.height * 0.06
        drawPillar(
            context: &context,
            in: CGRect(x: size.width * 0.02, y: y, width: sat.width, height: sat.height),
            colors: silver,
            playing: playing,
            online: online,
            groove: true)
        drawPillar(
            context: &context,
            in: CGRect(x: size.width * 0.85, y: y, width: sat.width, height: sat.height),
            colors: silver,
            playing: playing,
            online: online,
            groove: true)
    }
}

private func drawMove(context: inout GraphicsContext, size: CGSize, playing: Bool, online: Bool) {
    let body = box(0.18, 0.16, 0.64, 0.70, size)
    floorShadow(&context, under: body)
    let path = Path(roundedRect: body, cornerRadius: body.width / 2)
    let handle = CGRect(
        x: body.midX - body.width * 0.16,
        y: body.minY + body.height * 0.07,
        width: body.width * 0.32,
        height: body.height * 0.15)
    context.drawLayer { layer in
        layer.clip(to: path)
        layer.fill(
            path,
            with: shading(
                [Color(red: 0.40, green: 0.36, blue: 0.32), Color(red: 0.14, green: 0.13, blue: 0.12), Color(red: 0.26, green: 0.24, blue: 0.22)],
                from: CGPoint(x: body.minX, y: body.minY),
                to: CGPoint(x: body.maxX, y: body.maxY)))
        layer.blendMode = .destinationOut
        layer.fill(Path(roundedRect: handle, cornerRadius: handle.height / 2), with: .color(.black))
    }
    context.stroke(path, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
    context.stroke(
        Path(roundedRect: handle, cornerRadius: handle.height / 2),
        with: .color(MidnightGlass.gold.opacity(0.55)),
        lineWidth: 1)
    let mesh = CGRect(x: body.minX, y: handle.maxY + 4, width: body.width, height: body.maxY - handle.maxY - body.height * 0.16)
    context.drawLayer { layer in
        layer.clip(to: path)
        layer.clip(to: Path(mesh))
        grille(&layer, in: mesh, horizontal: true, step: max(1.6, body.height * 0.045))
    }
    led(&context, at: CGPoint(x: body.midX, y: body.maxY - body.height * 0.1), playing: playing, online: online, scale: body.width * 0.45)
}

private func drawMonolith(context: inout GraphicsContext, size: CGSize, playing: Bool, online: Bool) {
    let body = box(0.28, 0.08, 0.44, 0.84, size)
    floorShadow(&context, under: body)
    let path = Path(roundedRect: body, cornerRadius: size.width * 0.06)
    context.fill(
        path,
        with: shading(graphite, from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY)))
    let slot = CGRect(
        x: body.minX + body.width * 0.16,
        y: body.midY - body.height * 0.035,
        width: body.width * 0.68,
        height: body.height * 0.07)
    context.fill(Path(roundedRect: slot, cornerRadius: slot.height / 2), with: .color(Color.black.opacity(0.45)))
    context.stroke(path, with: .color(Color.white.opacity(0.2)), lineWidth: 1)
    led(&context, at: CGPoint(x: body.midX, y: body.maxY - body.height * 0.1), playing: playing, online: online, scale: body.width * 0.4)
}
