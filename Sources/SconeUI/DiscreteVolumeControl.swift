import SwiftUI
import SconeDomain

struct DiscreteVolumeControl: View {
    var volume: DiscreteVolume
    var compact: Bool = false
    var onChange: (DiscreteVolume) -> Void

    @State private var optimistic: DiscreteVolume?

    private var shown: DiscreteVolume { optimistic ?? volume }

    private static var steps: [DiscreteVolume] {
        DiscreteVolume.allCases.filter { $0 != .v0 }
    }

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            stepButton(systemName: "minus", delta: -1, enabled: shown > .v0)
            GeometryReader { proxy in
                ribBar(in: proxy.size)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 22 : 30)
            .layoutPriority(1)
            Text("\(shown.percent)%")
                .font((compact ? Font.caption2 : Font.subheadline).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
                .contentTransition(.numericText())
                .frame(width: compact ? 36 : 46, alignment: .trailing)
            stepButton(systemName: "plus", delta: 1, enabled: shown < .v100)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(shown.percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                commit(shown.stepped(by: 1))
            case .decrement:
                commit(shown.stepped(by: -1))
            @unknown default:
                break
            }
        }
        .onChange(of: volume) { _, _ in
            optimistic = nil
        }
    }

    private func ribBar(in size: CGSize) -> some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(Self.steps, id: \.self) { step in
                let filled = step <= shown
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        if filled {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [MidnightGlass.copper, MidnightGlass.gold],
                                        startPoint: .bottom,
                                        endPoint: .top))
                        }
                    }
                    .shadow(color: step == shown ? MidnightGlass.gold.opacity(0.9) : .clear, radius: 4)
                    .frame(height: step == shown ? size.height : size.height * 0.72)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    commit(detent(at: value.location.x, width: size.width))
                })
    }

    private func stepButton(systemName: String, delta: Int, enabled: Bool) -> some View {
        Button {
            commit(shown.stepped(by: delta))
        } label: {
            Image(systemName: systemName)
                .font(.system(size: compact ? 11 : 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(enabled ? 0.92 : 0.28))
                .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    private func detent(at x: CGFloat, width: CGFloat) -> DiscreteVolume {
        let steps = Self.steps
        guard width > 1, !steps.isEmpty else { return .v0 }
        if x <= 1 { return .v0 }
        let index = min(steps.count - 1, max(0, Int((x / width) * CGFloat(steps.count))))
        return steps[index]
    }

    private func commit(_ next: DiscreteVolume) {
        guard next != shown else { return }
        optimistic = next
        onChange(next)
        acousticTick()
    }
}
