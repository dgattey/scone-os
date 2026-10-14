/// A point on the house canvas, normalized to 0...1 on both axes. x runs west to east,
/// y runs north to south. Every initializer clamps, including decoding.
public struct RoomCoordinate: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double

    /// Non-finite components read as 0.5, the canvas center.
    public init(clampingX x: Double, y: Double) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        self.x = clamp(x)
        self.y = clamp(y)
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clampingX: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
    }
}

/// Speaker-to-speaker RF adjacency from `/status/proc/ath_rincon/status`, quantized into bands.
///
/// Quantizing is what keeps the floorplan still. Raw peer strength jitters between sweeps
/// (42 one minute, 44 the next). Bands absorb that, so an unchanged house produces an equal
/// matrix, and the deterministic layout produces equal coordinates.
public struct RFPeerMatrix: Hashable, Sendable, Codable {
    /// Thresholds are a guess fitted to the probe: the Bedroom/Guest link read 42/43 (same wing),
    /// the Basement links read 15 and 17 (across a floor).
    public enum Band: Int, Hashable, Sendable, Codable, Comparable {
        case weak = 1, moderate, strong
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var bands: [SpeakerPair: Band]

    public static let empty = RFPeerMatrix(bands: [:])

    private init(bands: [SpeakerPair: Band]) { self.bands = bands }

    public func band(_ a: SpeakerUUID, _ b: SpeakerUUID) -> Band? { bands[SpeakerPair(a, b)] }

    /// One `Node <mac> - FROM n : TO m` line, after the boundary resolved the MAC to a speaker.
    /// Keeps the stronger of both directions and of both speakers' reports. 0 means unmeasured.
    package mutating func record(_ a: SpeakerUUID, _ b: SpeakerUUID, from: Int, to: Int) {
        fatalError("not implemented")
    }
}

/// Unordered pair, so the Bedroom-to-Guest and Guest-to-Bedroom reports land on one key.
struct SpeakerPair: Hashable, Sendable, Codable {
    let low: SpeakerUUID
    let high: SpeakerUUID

    init(_ a: SpeakerUUID, _ b: SpeakerUUID) {
        (low, high) = a < b ? (a, b) : (b, a)
    }
}

public enum Placement: Hashable, Sendable {
    /// From `FloorplanLayout.infer`. Moves only when the household or an RF band changes.
    case inferred
    /// Dragged by the user. Stored in `floorplan-positions.json` and never moved by inference.
    case pinned
}

public struct FloorplanNode: Identifiable, Hashable, Sendable {
    public var id: SpeakerUUID { speaker.id }
    public let speaker: Speaker
    public let coordinate: RoomCoordinate
    public let placement: Placement
    /// nil while offline. Offline rooms render grayed at their position and belong to no group.
    public let group: GroupID?

    package init(speaker: Speaker, coordinate: RoomCoordinate, placement: Placement, group: GroupID?) {
        self.speaker = speaker
        self.coordinate = coordinate
        self.placement = placement
        self.group = group
    }
}

public enum FloorplanLayout {
    /// Deterministic stress layout over band distances (strong = near, weak = far, missing = a
    /// default distance). The seed positions come from sorted UUIDs and the iteration count is fixed,
    /// so equal input gives equal output. Rooms with no links take stable grid slots in UUID order.
    /// Pins do not feed the solve. Dragging one room never moves another.
    public static func infer(rooms: [SpeakerUUID], matrix: RFPeerMatrix) -> [SpeakerUUID: RoomCoordinate] {
        fatalError("not implemented")
    }
}
