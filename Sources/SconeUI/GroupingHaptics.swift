import SconeDomain
import SconeStore
import SwiftUI

/// The speaker a sidebar or compact-map drag started from. System drop targets only see the
/// payload on drop, so this is how they tell a real group target from the drag's own group.
@MainActor
enum SpeakerDragSource {
    private(set) static var current: SpeakerUUID?

    static func payload(_ speaker: SpeakerUUID) -> String {
        current = speaker
        return speaker.rawValue
    }
}

extension SconeState {
    func wouldRegroup(_ dragged: SpeakerUUID?, onto target: SpeakerUUID) -> Bool {
        guard let dragged, let targetGroup = groupID(containing: target) else { return false }
        return groupID(containing: dragged) != targetGroup
    }
}

extension View {
    /// Ticks once each time a drag reaches a new group target. Leaving a target, or staying on
    /// one, plays nothing. Pass nil for targets where a drop would not regroup.
    func groupTargetHaptic<Target: Equatable>(_ target: Target?) -> some View {
        sensoryFeedback(.alignment, trigger: target) { _, reached in reached != nil }
    }

    func groupingOutcomeHaptics(_ outcome: GroupingOutcome?) -> some View {
        sensoryFeedback(trigger: outcome) { _, outcome in outcome?.kind.feedback }
    }
}

private extension GroupingOutcome.Kind {
    // Mac trackpads only play .alignment and .levelChange, and have no error pattern.
    var feedback: SensoryFeedback? {
        #if os(macOS)
        switch self {
        case .grouped: .levelChange
        case .ungrouped: .alignment
        case .failed: nil
        }
        #else
        switch self {
        case .grouped: .success
        case .ungrouped: .impact(flexibility: .soft)
        case .failed: .error
        }
        #endif
    }
}
