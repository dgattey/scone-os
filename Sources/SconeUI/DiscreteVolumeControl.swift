import DylUI
import SwiftUI
import SconeDomain

struct DiscreteVolumeControl: View {
    var volume: DiscreteVolume
    var compact: Bool = false
    var onChange: (DiscreteVolume) -> Void

    @State private var optimistic: DiscreteVolume?
    @State private var isEditing = false
    @State private var lastCommitAt: Date = .distantPast
    @State private var lastTickAt: Date = .distantPast

    private var shown: DiscreteVolume { optimistic ?? volume }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(shown.percent) },
            set: { rawValue in
                let snapped = DiscreteVolume(snappingPercent: Int(rawValue.rounded()))
                commit(snapped)
            }
        )
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            stepButton(systemName: "speaker.minus.fill", delta: -1, enabled: shown > .v0)
            Slider(
                value: sliderBinding,
                in: 0...100,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .tint(MidnightGlass.gold)
            .controlSize(compact ? .small : .regular)
            .frame(maxWidth: .infinity)
            stepButton(systemName: "speaker.plus.fill", delta: 1, enabled: shown < .v100)
            Text("\(shown.percent)%")
                .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(MidnightGlass.primaryText.opacity(0.88))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.16), value: shown.percent)
                .frame(width: compact ? 36 : 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(shown.percent) percent")
        .onChange(of: volume) { _, newValue in
            guard !isEditing else { return }
            if newValue == optimistic || Date().timeIntervalSince(lastCommitAt) > 1.2 {
                optimistic = nil
            }
        }
    }

    private func stepButton(systemName: String, delta: Int, enabled: Bool) -> some View {
        Button {
            commit(shown.stepped(by: delta))
        } label: {
            Image(systemName: systemName)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(MidnightGlass.primaryText.opacity(enabled ? 0.88 : 0.28))
                .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                .background(Circle().fill(MidnightGlass.subtleFill))
                .overlay(Circle().strokeBorder(MidnightGlass.cardBorder, lineWidth: 0.75))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    private func commit(_ next: DiscreteVolume) {
        guard next != shown else { return }
        let now = Date()
        optimistic = next
        lastCommitAt = now
        onChange(next)
        if now.timeIntervalSince(lastTickAt) >= 0.055 {
            lastTickAt = now
            acousticTick()
        }
    }
}
