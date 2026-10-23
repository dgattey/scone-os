import SwiftUI
import SconeDomain

struct SpeakerSilhouetteView: View {
    var model: SpeakerModel
    var isOnline: Bool
    var isPlaying: Bool = false
    var isGrouped: Bool = false
    var size: CGFloat = 56

    private var active: Bool { isPlaying || isGrouped }

    private var fill: Color {
        if active {
            return MidnightGlass.gold
        }
        return MidnightGlass.primaryText.opacity(0.84)
    }

    var body: some View {
        ZStack {
            silhouetteShape
            if !isOnline {
                offlineSlash
            }
        }
        .frame(width: size, height: size)
        .opacity(isOnline ? 1 : 0.42)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var silhouetteShape: some View {
        switch model {
        case .arc, .beam, .ray, .playbar, .playbase:
            // Ultra-wide horizontal soundbar capsule with center acoustic slit cutout
            ZStack {
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.86, height: size * 0.19)
                Capsule(style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: size * 0.44, height: max(1.5, size * 0.04))
            }

        case .era300:
            // Pinched hourglass silhouette with inner waist cutout
            ZStack {
                Era300MinimalShape()
                    .fill(fill)
                    .frame(width: size * 0.60, height: size * 0.44)
                Capsule(style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: size * 0.22, height: max(1.6, size * 0.045))
            }

        case .era100, .one, .play1, .unrecognized:
            // Compact cylindrical speaker with top control ring cutout
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.38, height: size * 0.54)
                Capsule(style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: size * 0.18, height: max(1.8, size * 0.05))
                    .padding(.top, size * 0.065)
            }

        case .symfoniskBookshelf:
            // Tall, narrow architectural bookshelf monolith with offset vertical grille seam
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.27, height: size * 0.62)
                Capsule(style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: max(1.4, size * 0.032), height: size * 0.46)
                    .offset(x: -size * 0.045)
            }

        case .five, .play3:
            // Wide horizontal studio monitor with 3 acoustic driver cutouts
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.66, height: size * 0.40)
                HStack(spacing: size * 0.05) {
                    Circle()
                        .fill(MidnightGlass.cardFill)
                        .frame(width: size * 0.075, height: size * 0.075)
                    Circle()
                        .fill(MidnightGlass.cardFill)
                        .frame(width: size * 0.095, height: size * 0.095)
                    Circle()
                        .fill(MidnightGlass.cardFill)
                        .frame(width: size * 0.075, height: size * 0.075)
                }
            }

        case .move, .roam:
            // Portable speaker with recessed oval top handle notch
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.40, height: size * 0.60)
                Capsule(style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: size * 0.17, height: max(2.0, size * 0.055))
                    .padding(.top, size * 0.07)
            }

        case .sub, .subMini:
            // Subwoofer block with bold center force-canceling acoustic slot
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.52, height: size * 0.54)
                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                    .fill(MidnightGlass.cardFill)
                    .frame(width: size * 0.15, height: size * 0.30)
            }

        case .symfoniskLamp:
            // Table lamp silhouette
            VStack(spacing: size * 0.03) {
                UnevenRoundedRectangle(
                    topLeadingRadius: size * 0.14,
                    bottomLeadingRadius: size * 0.04,
                    bottomTrailingRadius: size * 0.04,
                    topTrailingRadius: size * 0.14,
                    style: .continuous
                )
                .fill(fill)
                .frame(width: size * 0.44, height: size * 0.26)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.28, height: size * 0.26)
            }

        case .symfoniskFrame:
            // Architectural picture frame silhouette
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.46, height: size * 0.56)
                RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                    .strokeBorder(MidnightGlass.cardFill, lineWidth: max(1.2, size * 0.045))
                    .frame(width: size * 0.32, height: size * 0.42)
            }

        case .amp, .port:
            // Compact hi-fi component block with front volume ring cutout
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                    .fill(fill)
                    .frame(width: size * 0.50, height: size * 0.28)
                Circle()
                    .strokeBorder(MidnightGlass.cardFill, lineWidth: max(1.4, size * 0.035))
                    .frame(width: size * 0.09, height: size * 0.09)
            }
        }
    }

    private var offlineSlash: some View {
        Capsule()
            .fill(MidnightGlass.cardFill)
            .frame(width: size * 0.72, height: max(2.5, size * 0.09))
            .overlay {
                Capsule()
                    .fill(fill)
                    .frame(width: size * 0.68, height: max(1.5, size * 0.045))
            }
            .rotationEffect(.degrees(-42))
    }
}

private struct Era300MinimalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let pinchX = w * 0.10
        let pinchY = h * 0.09
        var p = Path()
        p.move(to: CGPoint(x: w * 0.16, y: 0))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.84, y: 0),
            control: CGPoint(x: w * 0.5, y: pinchY)
        )
        p.addQuadCurve(
            to: CGPoint(x: w, y: h * 0.22),
            control: CGPoint(x: w, y: 0)
        )
        p.addQuadCurve(
            to: CGPoint(x: w, y: h * 0.78),
            control: CGPoint(x: w - pinchX, y: h * 0.5)
        )
        p.addQuadCurve(
            to: CGPoint(x: w * 0.84, y: h),
            control: CGPoint(x: w, y: h)
        )
        p.addQuadCurve(
            to: CGPoint(x: w * 0.16, y: h),
            control: CGPoint(x: w * 0.5, y: h - pinchY)
        )
        p.addQuadCurve(
            to: CGPoint(x: 0, y: h * 0.78),
            control: CGPoint(x: 0, y: h)
        )
        p.addQuadCurve(
            to: CGPoint(x: 0, y: h * 0.22),
            control: CGPoint(x: pinchX, y: h * 0.5)
        )
        p.addQuadCurve(
            to: CGPoint(x: w * 0.16, y: 0),
            control: CGPoint(x: 0, y: 0)
        )
        p.closeSubpath()
        return p
    }
}

struct SpeakerBatteryBadge: View {
    var battery: BatteryTelemetry

    private var iconName: String {
        if battery.isOnCharger {
            return "battery.100percent.bolt"
        }
        switch battery.levelPercent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 15..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var tint: Color {
        if battery.isOnCharger { return Color.green }
        if battery.levelPercent <= 20 { return Color.orange }
        return MidnightGlass.secondaryText
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
            Text("\(battery.levelPercent)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(MidnightGlass.subtleFill))
        .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
        .fixedSize()
        .help(battery.isOnCharger ? "Battery \(battery.levelPercent)% (Charging)" : "Battery \(battery.levelPercent)%")
    }
}
