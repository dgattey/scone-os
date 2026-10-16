import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat, CGFloat)
) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        let c = (match == .darkAqua) ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
    })
    #elseif os(iOS)
    return Color(uiColor: UIColor { traits in
        let c = (traits.userInterfaceStyle == .dark) ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
    })
    #endif
}

enum MidnightGlass {
    // Background surfaces:
    // Light: Warm clotted-cream / oat parchment (#FAF5EC -> #F3EAD8)
    // Dark: Deep roasted espresso / hearth (#16120E -> #1E1813)
    static let obsidian = adaptiveColor(
        light: (250 / 255, 245 / 255, 236 / 255, 1.0),
        dark: (22 / 255, 18 / 255, 14 / 255, 1.0)
    )
    static let slate = adaptiveColor(
        light: (243 / 255, 234 / 255, 216 / 255, 1.0),
        dark: (30 / 255, 24 / 255, 19 / 255, 1.0)
    )

    // Accents:
    // Light: Golden honey / jam (#C87D20 / #B86B14)
    // Dark: Golden-butter & amber (#E5A93C / #C88232)
    static let gold = adaptiveColor(
        light: (200 / 255, 125 / 255, 32 / 255, 1.0),
        dark: (229 / 255, 169 / 255, 60 / 255, 1.0)
    )
    static let copper = adaptiveColor(
        light: (184 / 255, 107 / 255, 20 / 255, 1.0),
        dark: (200 / 255, 130 / 255, 50 / 255, 1.0)
    )

    // Typography:
    // Light: Espresso / roasted-barley (#2A1E14 primary, #6E5A48 secondary)
    // Dark: Warm cream (#F7EFE4 primary, #BDAE9C secondary)
    static let primaryText = adaptiveColor(
        light: (42 / 255, 30 / 255, 20 / 255, 1.0),
        dark: (247 / 255, 239 / 255, 228 / 255, 1.0)
    )
    static let secondaryText = adaptiveColor(
        light: (110 / 255, 90 / 255, 72 / 255, 1.0),
        dark: (189 / 255, 174 / 255, 156 / 255, 1.0)
    )
    static let tertiaryText = adaptiveColor(
        light: (140 / 255, 118 / 255, 96 / 255, 1.0),
        dark: (148 / 255, 132 / 255, 116 / 255, 1.0)
    )

    // Contrast ink on gold/honey buttons
    static let ink = adaptiveColor(
        light: (255 / 255, 253 / 255, 249 / 255, 1.0),
        dark: (26 / 255, 18 / 255, 11 / 255, 1.0)
    )

    // Card & container surfaces:
    // Light: Warm toasted scone crust card (#FFFDF9) with #E5D5B8 border
    // Dark: Warm glazed espresso card (#261E17) with warm amber border
    static let cardFill = adaptiveColor(
        light: (255 / 255, 253 / 255, 249 / 255, 0.94),
        dark: (38 / 255, 30 / 255, 23 / 255, 0.84)
    )
    static let cardElevatedFill = adaptiveColor(
        light: (255 / 255, 253 / 255, 249 / 255, 0.98),
        dark: (48 / 255, 38 / 255, 29 / 255, 0.92)
    )
    static let cardBorder = adaptiveColor(
        light: (229 / 255, 213 / 255, 184 / 255, 0.95),
        dark: (247 / 255, 239 / 255, 228 / 255, 0.16)
    )
    static let subtleFill = adaptiveColor(
        light: (238 / 255, 226 / 255, 205 / 255, 0.65),
        dark: (247 / 255, 239 / 255, 228 / 255, 0.08)
    )
    static let floorBandFill = adaptiveColor(
        light: (247 / 255, 239 / 255, 224 / 255, 0.82),
        dark: (32 / 255, 25 / 255, 19 / 255, 0.68)
    )
    static let floorBandBorder = adaptiveColor(
        light: (222 / 255, 202 / 255, 170 / 255, 0.90),
        dark: (229 / 255, 169 / 255, 60 / 255, 0.18)
    )
    static let roomEnclosureFill = adaptiveColor(
        light: (255 / 255, 252 / 255, 245 / 255, 0.86),
        dark: (44 / 255, 35 / 255, 27 / 255, 0.66)
    )
    static let roomEnclosureBorder = adaptiveColor(
        light: (216 / 255, 192 / 255, 154 / 255, 0.85),
        dark: (229 / 255, 169 / 255, 60 / 255, 0.24)
    )
    static let badgeBackground = adaptiveColor(
        light: (250 / 255, 243 / 255, 230 / 255, 0.96),
        dark: (24 / 255, 19 / 255, 15 / 255, 0.94)
    )
}

struct MidnightBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [MidnightGlass.obsidian, MidnightGlass.slate],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            RadialGradient(
                colors: [
                    MidnightGlass.copper.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 460)
            RadialGradient(
                colors: [
                    MidnightGlass.gold.opacity(colorScheme == .dark ? 0.10 : 0.08),
                    .clear,
                ],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

struct MidnightGlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var glowing: Bool = false
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(glowing ? MidnightGlass.cardElevatedFill : MidnightGlass.cardFill)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.02 : 0.35),
                        (glowing ? MidnightGlass.gold : Color.white).opacity(colorScheme == .dark ? (glowing ? 0.65 : 0.25) : 0.85),
                        Color.white.opacity(colorScheme == .dark ? 0.04 : 0.35),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.horizontal, radius * 0.7)
                    .padding(.top, 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: glowing
                                ? [MidnightGlass.gold.opacity(0.92), MidnightGlass.copper.opacity(0.42)]
                                : [MidnightGlass.cardBorder, MidnightGlass.cardBorder.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: glowing ? 1.4 : 1)
            }
            .shadow(
                color: glowing
                    ? MidnightGlass.copper.opacity(colorScheme == .dark ? 0.34 : 0.18)
                    : Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07),
                radius: glowing ? 16 : 10,
                y: 6)
    }
}

extension View {
    func midnightGlass(glowing: Bool = false, radius: CGFloat = 22) -> some View {
        modifier(MidnightGlassCard(glowing: glowing, radius: radius))
    }
}

struct SconeConeWedgeShape: Shape {
    var dyOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 824.0
        let ox = rect.minX - 100.0 * scale
        let oy = rect.minY - 100.0 * scale
        let ax = ox + 296.0 * scale
        let cy = oy + (478.0 + dyOffset) * scale
        let radius = 232.0 * scale
        let half = Angle.degrees(36)

        var p = Path()
        p.move(to: CGPoint(x: ax, y: cy))
        p.addLine(
            to: CGPoint(
                x: ax + radius * CGFloat(cos(-half.radians)),
                y: cy + radius * CGFloat(sin(-half.radians))
            )
        )
        p.addArc(
            center: CGPoint(x: ax, y: cy),
            radius: radius,
            startAngle: -half,
            endAngle: half,
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

struct SconeConeSoundArcShape: Shape {
    var radiusUnits: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 824.0
        let ox = rect.minX - 100.0 * scale
        let oy = rect.minY - 100.0 * scale
        let ax = ox + 296.0 * scale
        let cy = oy + 511.0 * scale
        let radius = radiusUnits * scale
        let half = Angle.degrees(36)

        var p = Path()
        p.addArc(
            center: CGPoint(x: ax, y: cy),
            radius: radius,
            startAngle: -half,
            endAngle: half,
            clockwise: false
        )
        return p
    }
}

struct SconeBrandEmblem: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 26
    var showContainer: Bool = true

    private var motifScale: CGFloat {
        showContainer ? (size / 824.0) : (size / 640.0)
    }

    var body: some View {
        ZStack {
            if showContainer {
                RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                    .fill(backgroundGradient)
                    .overlay(
                        RadialGradient(
                            colors: [
                                (colorScheme == .dark
                                    ? Color(red: 0.898, green: 0.663, blue: 0.235).opacity(0.30)
                                    : Color(red: 0.949, green: 0.698, blue: 0.290).opacity(0.22)),
                                .clear,
                            ],
                            center: .init(x: 0.50, y: 0.53),
                            startRadius: 0,
                            endRadius: size * 0.48
                        )
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.226, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                            .strokeBorder(borderGradient, lineWidth: max(0.85, size * 0.032))
                    )
            }

            sconeConeArtwork
                .frame(width: 824.0 * motifScale, height: 824.0 * motifScale)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var sconeConeArtwork: some View {
        let s = motifScale
        let wedgeStroke = 40.0 * s
        let arcStroke = (size <= 36 ? 56.0 : 50.0) * s
        let specStroke = max(0.75, 7.5 * s)

        return ZStack {
            // Outer and inner honey-glass sound arcs
            ForEach([(432.0, colorScheme == .dark ? 0.62 : 0.82), (336.0, colorScheme == .dark ? 0.96 : 1.0)], id: \.0) { r, op in
                ZStack {
                    if colorScheme == .dark {
                        SconeConeSoundArcShape(radiusUnits: r)
                            .stroke(
                                Color(red: 0.898, green: 0.663, blue: 0.235).opacity(0.38 * op),
                                style: StrokeStyle(lineWidth: 64.0 * s, lineCap: .round)
                            )
                            .blur(radius: 18.0 * s)
                    }

                    SconeConeSoundArcShape(radiusUnits: r)
                        .stroke(
                            soundArcGradient,
                            style: StrokeStyle(lineWidth: arcStroke, lineCap: .round)
                        )
                        .shadow(
                            color: shadowColor,
                            radius: 14.0 * s,
                            y: 12.0 * s
                        )

                    SconeConeSoundArcShape(radiusUnits: r + 12.0)
                        .stroke(
                            Color.white.opacity(0.58),
                            style: StrokeStyle(lineWidth: specStroke, lineCap: .round)
                        )
                }
                .opacity(op)
            }

            // 3D biscuit side extrusion
            ZStack {
                ForEach([66.0, 52.0, 38.0, 24.0, 12.0], id: \.self) { dy in
                    let t = pow(dy / 66.0, 1.6)
                    let col = biscuitLayerColor(t: t)
                    SconeConeWedgeShape(dyOffset: dy)
                        .fill(col)
                        .overlay(
                            SconeConeWedgeShape(dyOffset: dy)
                                .stroke(col, style: StrokeStyle(lineWidth: wedgeStroke, lineJoin: .round))
                        )
                }
            }
            .shadow(color: shadowColor, radius: 16.0 * s, y: 14.0 * s)

            // Top golden-baked scone wedge
            SconeConeWedgeShape(dyOffset: 0)
                .fill(sconeTopGradient)
                .overlay(
                    SconeConeWedgeShape(dyOffset: 0)
                        .stroke(sconeTopGradient, style: StrokeStyle(lineWidth: wedgeStroke, lineJoin: .round))
                )
                .overlay(
                    SconeConeWedgeShape(dyOffset: -10)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.965, blue: 0.863).opacity(0.75),
                                    .clear,
                                ],
                                center: .init(x: 0.37, y: 0.39),
                                startRadius: 0,
                                endRadius: 150.0 * s
                            )
                        )
                )
        }
    }

    private func biscuitLayerColor(t: Double) -> Color {
        let r = 0.969 + (0.639 - 0.969) * t
        let g = 0.863 + (0.337 - 0.863) * t
        let b = 0.651 + (0.086 - 0.651) * t
        return Color(red: r, green: g, blue: b)
    }

    private var sconeTopGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 1.000, green: 0.812, blue: 0.486),
                    Color(red: 0.878, green: 0.580, blue: 0.204),
                    Color(red: 0.663, green: 0.349, blue: 0.102),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.961, green: 0.745, blue: 0.384),
                    Color(red: 0.843, green: 0.533, blue: 0.173),
                    Color(red: 0.663, green: 0.349, blue: 0.102),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var soundArcGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 1.000, green: 0.878, blue: 0.561),
                    Color(red: 0.878, green: 0.537, blue: 0.165),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.957, green: 0.737, blue: 0.353),
                    Color(red: 0.722, green: 0.392, blue: 0.102),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var backgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.227, green: 0.169, blue: 0.122),
                    Color(red: 0.071, green: 0.051, blue: 0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 1.000, green: 0.984, blue: 0.953),
                    Color(red: 0.933, green: 0.867, blue: 0.753),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.32),
                    Color.white.opacity(0.06),
                    Color(red: 0.898, green: 0.663, blue: 0.235).opacity(0.35),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.85),
                    Color.white.opacity(0.15),
                    Color(red: 0.788, green: 0.635, blue: 0.451).opacity(0.45),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.50)
            : Color(red: 0.353, green: 0.196, blue: 0.063).opacity(0.28)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct OfflinePill: View {
    var body: some View {
        Text("Offline")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(MidnightGlass.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(MidnightGlass.subtleFill))
            .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
    }
}

struct PlayingMark: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(MidnightGlass.ink)
            .padding(5)
            .background(Circle().fill(MidnightGlass.gold))
            .shadow(color: MidnightGlass.gold.opacity(0.55), radius: 5)
    }
}

@MainActor
func acousticTick() {
    #if os(macOS)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    #elseif os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
}
