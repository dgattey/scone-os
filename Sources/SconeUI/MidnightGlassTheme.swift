import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum MidnightGlass {
    static let obsidian = Color(red: 9 / 255, green: 11 / 255, blue: 16 / 255)
    static let slate = Color(red: 17 / 255, green: 21 / 255, blue: 32 / 255)
    static let copper = Color(red: 217 / 255, green: 155 / 255, blue: 82 / 255)
    static let gold = Color(red: 232 / 255, green: 184 / 255, blue: 109 / 255)
    static let ink = Color(red: 0.09, green: 0.07, blue: 0.05)
}

struct MidnightBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [MidnightGlass.obsidian, MidnightGlass.slate],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            RadialGradient(
                colors: [MidnightGlass.copper.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 460)
            RadialGradient(
                colors: [MidnightGlass.gold.opacity(0.08), .clear],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

struct MidnightGlassCard: ViewModifier {
    var glowing: Bool = false
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.02),
                        Color.white.opacity(glowing ? 0.9 : 0.55),
                        Color.white.opacity(0.05),
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
                                ? [MidnightGlass.gold.opacity(0.95), MidnightGlass.copper.opacity(0.28)]
                                : [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .shadow(
                color: glowing ? MidnightGlass.copper.opacity(0.38) : Color.black.opacity(0.28),
                radius: glowing ? 18 : 12,
                y: 10)
    }
}

extension View {
    func midnightGlass(glowing: Bool = false, radius: CGFloat = 22) -> some View {
        modifier(MidnightGlassCard(glowing: glowing, radius: radius))
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
            .foregroundStyle(Color.white.opacity(0.78))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

struct PlayingMark: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(MidnightGlass.ink)
            .padding(5)
            .background(Circle().fill(MidnightGlass.gold))
            .shadow(color: MidnightGlass.gold.opacity(0.7), radius: 6)
    }
}

func acousticTick() {
    #if os(macOS)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    #elseif os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
}
