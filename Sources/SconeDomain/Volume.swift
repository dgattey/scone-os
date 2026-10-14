/// Volume in 5% detents. These 21 values are the only volumes SconeOS can hold, show, or send.
///
/// Continuous input converts at the edge through `init(snappingPercent:)` (the wire: a speaker
/// reporting 24 reads as 25) or `init(snappingFraction:)` (a slider), and is never stored.
public enum DiscreteVolume: Int, CaseIterable, Comparable, Codable, Sendable {
    case v0 = 0, v5 = 5, v10 = 10, v15 = 15, v20 = 20, v25 = 25, v30 = 30
    case v35 = 35, v40 = 40, v45 = 45, v50 = 50, v55 = 55, v60 = 60, v65 = 65
    case v70 = 70, v75 = 75, v80 = 80, v85 = 85, v90 = 90, v95 = 95, v100 = 100

    /// Nearest detent, clamped to 0...100. 22 reads as 20, 23 reads as 25.
    public init(snappingPercent percent: Int) {
        let clamped = min(max(percent, 0), 100)
        self = Self.allCases[(clamped + 2) / 5]
    }

    /// Slider position in 0...1. Non-finite input reads as 0.
    public init(snappingFraction fraction: Double) {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.init(snappingPercent: Int((clamped * 100).rounded()))
    }

    /// Moves by whole detents and clamps at the ends. +1 from 95 is 100, +1 from 100 is 100.
    public func stepped(by detents: Int) -> DiscreteVolume {
        let last = Self.allCases.count - 1
        let delta = min(max(detents, -last), last)
        return Self.allCases[min(max(rawValue / 5 + delta, 0), last)]
    }

    public var percent: Int { rawValue }
    public var fraction: Double { Double(rawValue) / 100 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum VolumeTarget: Hashable, Sendable {
    /// Per-speaker `RenderingControl`. Valid on any visible speaker, grouped or not.
    case speaker(SpeakerUUID)
    /// `GroupRenderingControl` on the coordinator. Sonos rescales members proportionally.
    case group(GroupID)
}
