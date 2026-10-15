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

struct SconeOrganicWaveSilhouetteShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.minX
        let oy = rect.minY

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: ox + side * nx, y: oy + side * ny)
        }

        let leftCapX: CGFloat = 0.145
        let leftCapY: CGFloat = 0.50
        let rightCapX: CGFloat = 0.855
        let rightCapY: CGFloat = 0.50

        let topExtrema: [(CGFloat, CGFloat)] = [
            (0.215, 0.375),
            (0.288, 0.468),
            (0.358, 0.250),
            (0.429, 0.448),
            (0.500, 0.160),
            (0.571, 0.448),
            (0.642, 0.250),
            (0.712, 0.468),
            (0.785, 0.375),
        ]
        let bottomExtrema: [(CGFloat, CGFloat)] = [
            (0.215, 0.625),
            (0.288, 0.532),
            (0.358, 0.750),
            (0.429, 0.552),
            (0.500, 0.840),
            (0.571, 0.552),
            (0.642, 0.750),
            (0.712, 0.532),
            (0.785, 0.625),
        ]

        var p = Path()
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
}

struct SconeOrganicGlazeCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.minX
        let oy = rect.minY

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: ox + side * nx, y: oy + side * ny)
        }

        var p = Path()
        p.move(to: pt(0.08, 0.53))
        p.addCurve(
            to: pt(0.50, 0.49),
            control1: pt(0.24, 0.44),
            control2: pt(0.36, 0.55)
        )
        p.addCurve(
            to: pt(0.92, 0.47),
            control1: pt(0.64, 0.43),
            control2: pt(0.76, 0.54)
        )
        p.addCurve(
            to: pt(0.50, 0.04),
            control1: pt(0.94, 0.14),
            control2: pt(0.72, 0.04)
        )
        p.addCurve(
            to: pt(0.08, 0.53),
            control1: pt(0.28, 0.04),
            control2: pt(0.06, 0.14)
        )
        p.closeSubpath()
        return p
    }
}

struct SconeBrandEmblem: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 26
    var showContainer: Bool = true

    var body: some View {
        ZStack {
            if showContainer {
                RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                    .fill(backgroundGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                            .strokeBorder(borderStroke, lineWidth: max(0.75, size * 0.03))
                    )
            }

            ZStack {
                Rectangle()
                    .fill(sconeBaseGradient)

                SconeOrganicGlazeCrownShape()
                    .fill(sconeGlazeGradient)
            }
            .clipShape(SconeOrganicWaveSilhouetteShape())
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var sconeGlazeGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.89, blue: 0.48),
                    Color(red: 0.95, green: 0.62, blue: 0.19),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.83, blue: 0.38),
                    Color(red: 0.91, green: 0.57, blue: 0.16),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var sconeBaseGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.85, green: 0.48, blue: 0.15),
                    Color(red: 0.68, green: 0.34, blue: 0.09),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.80, green: 0.44, blue: 0.13),
                    Color(red: 0.64, green: 0.31, blue: 0.08),
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
                    Color(red: 0.125, green: 0.092, blue: 0.068),
                    Color(red: 0.072, green: 0.052, blue: 0.038),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.962, blue: 0.922),
                    Color(red: 0.935, green: 0.888, blue: 0.808),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderStroke: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.90, blue: 0.72).opacity(0.26)
            : Color(red: 0.76, green: 0.58, blue: 0.34).opacity(0.34)
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
