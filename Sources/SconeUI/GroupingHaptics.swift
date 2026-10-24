import CoreHaptics
import SconeDomain
import SconeStore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The speaker a sidebar or compact-map drag started from. System drop targets only see the
/// payload on drop, so this is how they tell a real group target from the drag's own group.
@MainActor
enum SpeakerDragSource {
    private(set) static var current: SpeakerUUID?

    static func payload(_ speaker: SpeakerUUID) -> String {
        current = speaker
        #if os(macOS)
        GroupingHaptics.shared.play(.pickedUp)
        #endif
        return speaker.rawValue
    }

    static func dropped() {
        current = nil
    }
}

extension SconeState {
    func wouldRegroup(_ dragged: SpeakerUUID?, onto target: SpeakerUUID) -> Bool {
        guard let dragged, let targetGroup = groupID(containing: target) else { return false }
        return groupID(containing: dragged) != targetGroup
    }
}

/// The grouping haptics, from subtle to strong, plus a separate error pattern.
enum GroupingHaptic: Hashable, CaseIterable {
    /// A drag picked up a speaker, reached a new group target, or set a room down away from any target.
    case tick
    /// A regroup went out: a drop on a target, or a menu, button or preset.
    case snap
    /// Sonos joined the speakers. Two beats, rising.
    case joined
    /// Sonos split a speaker off or dissolved a group. Two beats, falling.
    case split
    /// Sonos failed or only partly applied a regroup.
    case failed
}

/// Every grouping moment the app can see, and the one table from moment to haptic.
enum GroupingEvent: Hashable {
    case pickedUp
    case reachedTarget
    case setDown
    case command(GroupingCommandEvent.Kind)

    var haptic: GroupingHaptic {
        switch self {
        case .pickedUp, .reachedTarget, .setDown: .tick
        case .command(.sent): .snap
        case .command(.grouped): .joined
        case .command(.ungrouped): .split
        case .command(.failed): .failed
        }
    }
}

struct HapticPulse: Hashable {
    var at: TimeInterval
    var intensity: Float
    var sharpness: Float
}

extension GroupingHaptic {
    /// Core Haptics transients on iPhone.
    var pulses: [HapticPulse] {
        switch self {
        case .tick:
            [HapticPulse(at: 0, intensity: 0.55, sharpness: 0.75)]
        case .snap:
            [HapticPulse(at: 0, intensity: 0.9, sharpness: 1.0)]
        case .joined:
            [HapticPulse(at: 0, intensity: 0.75, sharpness: 0.5), HapticPulse(at: 0.1, intensity: 1.0, sharpness: 0.8)]
        case .split:
            [HapticPulse(at: 0, intensity: 1.0, sharpness: 0.8), HapticPulse(at: 0.1, intensity: 0.75, sharpness: 0.5)]
        case .failed:
            [
                HapticPulse(at: 0, intensity: 1.0, sharpness: 0.3),
                HapticPulse(at: 0.09, intensity: 1.0, sharpness: 0.3),
                HapticPulse(at: 0.18, intensity: 1.0, sharpness: 0.3),
            ]
        }
    }
}

#if os(macOS)
struct TrackpadPulse: Hashable {
    var at: TimeInterval
    var pattern: NSHapticFeedbackManager.FeedbackPattern
}

extension GroupingHaptic {
    /// Force Touch trackpads only play three fixed patterns, so strength comes from pattern choice and beat count.
    var trackpadPulses: [TrackpadPulse] {
        switch self {
        case .tick:
            [TrackpadPulse(at: 0, pattern: .alignment)]
        case .snap:
            [TrackpadPulse(at: 0, pattern: .levelChange)]
        case .joined:
            [TrackpadPulse(at: 0, pattern: .generic), TrackpadPulse(at: 0.1, pattern: .levelChange)]
        case .split:
            [TrackpadPulse(at: 0, pattern: .levelChange), TrackpadPulse(at: 0.1, pattern: .generic)]
        case .failed:
            [
                TrackpadPulse(at: 0, pattern: .levelChange),
                TrackpadPulse(at: 0.1, pattern: .levelChange),
                TrackpadPulse(at: 0.2, pattern: .levelChange),
            ]
        }
    }
}
#endif

/// Keeps ticks from stuttering. Any two ticks need `minimumGap` between them, and re-reaching the same target
/// needs `reentryGap` of quiet first, so jitter at the edge of a drop target never repeats.
struct TickGate {
    static let minimumGap: Duration = .milliseconds(100)
    static let reentryGap: Duration = .milliseconds(400)
    private var lastTick: ContinuousClock.Instant?
    private var lastTarget: AnyHashable?
    private var lastReach: ContinuousClock.Instant?

    mutating func reset() {
        lastTarget = nil
        lastReach = nil
    }

    /// `target` is nil for ticks that aren't about a target (pickup, set down).
    mutating func allows(target: AnyHashable?, at now: ContinuousClock.Instant) -> Bool {
        if let target, target == lastTarget, let lastReach, lastReach.duration(to: now) < Self.reentryGap {
            self.lastReach = now
            return false
        }
        if let lastTick, lastTick.duration(to: now) < Self.minimumGap {
            return false
        }
        lastTick = now
        if let target {
            lastTarget = target
            lastReach = now
        }
        return true
    }
}

@MainActor
final class GroupingHaptics {
    static let shared = GroupingHaptics()

    private var gate = TickGate()
    private var engine: CHHapticEngine?
    private var players: [GroupingHaptic: any CHHapticPatternPlayer] = [:]

    /// Starts the haptic engine and builds every pattern's player ahead of the first event.
    func prepare() {
        #if !os(macOS)
        startEngine()
        #endif
    }

    func play(_ event: GroupingEvent) {
        if event == .pickedUp {
            gate.reset()
            prepare()
        }
        switch event.haptic {
        case .tick: playGated(.tick, target: nil)
        case .snap, .joined, .split, .failed: perform(event.haptic)
        }
    }

    /// A drag reached a target where a drop would regroup.
    func reached(_ target: AnyHashable) {
        playGated(GroupingEvent.reachedTarget.haptic, target: target)
    }

    private func playGated(_ haptic: GroupingHaptic, target: AnyHashable?) {
        guard gate.allows(target: target, at: ContinuousClock.now) else { return }
        perform(haptic)
    }

    private func perform(_ haptic: GroupingHaptic) {
        #if os(macOS)
        performOnTrackpad(haptic.trackpadPulses)
        #else
        performWithCoreHaptics(haptic)
        #endif
    }

    #if os(macOS)
    private func performOnTrackpad(_ pulses: [TrackpadPulse]) {
        for pulse in pulses where pulse.at <= 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(pulse.pattern, performanceTime: .now)
        }
        let later = pulses.filter { $0.at > 0 }
        guard !later.isEmpty else { return }
        Task { @MainActor in
            var elapsed: TimeInterval = 0
            for pulse in later {
                try? await Task.sleep(for: .seconds(pulse.at - elapsed))
                elapsed = pulse.at
                NSHapticFeedbackManager.defaultPerformer.perform(pulse.pattern, performanceTime: .now)
            }
        }
    }
    #endif

    private func startEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if engine == nil {
            guard let created = try? CHHapticEngine() else { return }
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true
            // Core Haptics calls this on its own queue, so it must not inherit main-actor isolation.
            created.resetHandler = { @Sendable [weak self] in
                Task { @MainActor [weak self] in self?.engineReset() }
            }
            engine = created
            buildPlayers()
        }
        engine?.start(completionHandler: nil)
    }

    private func engineReset() {
        try? engine?.start()
        buildPlayers()
    }

    private func buildPlayers() {
        guard let engine else { return }
        players = [:]
        for haptic in GroupingHaptic.allCases {
            let events = haptic.pulses.map { pulse in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
                    ],
                    relativeTime: pulse.at
                )
            }
            guard let pattern = try? CHHapticPattern(events: events, parameters: []) else { continue }
            players[haptic] = try? engine.makePlayer(with: pattern)
        }
    }

    private func performWithCoreHaptics(_ haptic: GroupingHaptic) {
        if engine == nil { startEngine() }
        guard let engine, let player = players[haptic] else { return }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            try? engine.start()
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }
}

extension View {
    /// Ticks when a drag reaches a target where a drop would regroup. Pass nil everywhere else. Leaving a target
    /// plays nothing.
    func groupTargetHaptic<Target: Hashable>(_ target: Target?) -> some View {
        onChange(of: target) { _, reached in
            if let reached { GroupingHaptics.shared.reached(AnyHashable(reached)) }
        }
    }

    /// Plays each regroup this app sends: a snap when it goes out, then the result once Sonos finishes it.
    func groupingCommandHaptics(_ event: GroupingCommandEvent?) -> some View {
        onChange(of: event) { _, event in
            if let event { GroupingHaptics.shared.play(.command(event.kind)) }
        }
        .task { GroupingHaptics.shared.prepare() }
    }
}
