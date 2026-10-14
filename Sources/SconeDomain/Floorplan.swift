public struct RoomCoordinate: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double

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

public struct RFPeerMatrix: Hashable, Sendable, Codable {
    public enum Band: Int, Hashable, Sendable, Codable, Comparable {
        case weak = 1, moderate, strong
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var bands: [SpeakerPair: Band]

    public static let empty = RFPeerMatrix(bands: [:])

    private init(bands: [SpeakerPair: Band]) { self.bands = bands }

    public func band(_ a: SpeakerUUID, _ b: SpeakerUUID) -> Band? { bands[SpeakerPair(a, b)] }

    package mutating func record(_ a: SpeakerUUID, _ b: SpeakerUUID, from: Int, to: Int) {
        guard a != b else { return }
        let strength = max(from, to)
        guard strength > 0 else { return }
        let band: Band = if strength >= 35 { .strong } else if strength >= 20 { .moderate } else { .weak }
        let key = SpeakerPair(a, b)
        bands[key] = max(band, bands[key] ?? band)
    }
}

struct SpeakerPair: Hashable, Sendable, Codable {
    let low: SpeakerUUID
    let high: SpeakerUUID

    init(_ a: SpeakerUUID, _ b: SpeakerUUID) {
        (low, high) = a < b ? (a, b) : (b, a)
    }
}

public enum Placement: Hashable, Sendable {
    case inferred
    case pinned
}

public struct FloorplanNode: Identifiable, Hashable, Sendable {
    public var id: SpeakerUUID { speaker.id }
    public let speaker: Speaker
    public let coordinate: RoomCoordinate
    public let placement: Placement
    public let group: GroupID?

    package init(speaker: Speaker, coordinate: RoomCoordinate, placement: Placement, group: GroupID?) {
        self.speaker = speaker
        self.coordinate = coordinate
        self.placement = placement
        self.group = group
    }
}

public enum FloorplanLayout {
    public static func infer(rooms: [SpeakerUUID], matrix: RFPeerMatrix) -> [SpeakerUUID: RoomCoordinate] {
        let ordered = Array(Set(rooms)).sorted()
        guard !ordered.isEmpty else { return [:] }

        var x: [SpeakerUUID: Int] = [:]
        var y: [SpeakerUUID: Int] = [:]
        let unknown = ordered.filter { priorHundredths[$0.rawValue] == nil }
        let columns = max(1, Int(Double(unknown.count).squareRoot().rounded(.up)))
        let rows = max(1, (unknown.count + columns - 1) / columns)
        for (index, id) in unknown.enumerated() {
            let column = index % columns
            let row = index / columns
            x[id] = hundredths(Double(column + 1) / Double(columns + 1))
            y[id] = hundredths(Double(row + 1) / Double(rows + 1))
        }
        for id in ordered {
            guard let prior = priorHundredths[id.rawValue] else { continue }
            x[id] = prior.x
            y[id] = prior.y
        }

        var deltaX: [SpeakerUUID: Int] = [:]
        var deltaY: [SpeakerUUID: Int] = [:]
        for left in ordered.indices {
            for right in (left + 1)..<ordered.count {
                let a = ordered[left]
                let b = ordered[right]
                guard let band = matrix.band(a, b), let pull = pullPercent(band),
                      let ax = x[a], let ay = y[a], let bx = x[b], let by = y[b] else { continue }
                let dx = Int((Double(bx - ax) * Double(pull) / 100).rounded())
                let dy = Int((Double(by - ay) * Double(pull) / 100).rounded())
                deltaX[a, default: 0] += dx
                deltaY[a, default: 0] += dy
                deltaX[b, default: 0] -= dx
                deltaY[b, default: 0] -= dy
            }
        }

        var layout: [SpeakerUUID: RoomCoordinate] = [:]
        for id in ordered {
            guard let px = x[id], let py = y[id] else { continue }
            layout[id] = RoomCoordinate(
                clampingX: Double(px + (deltaX[id] ?? 0)) / 100,
                y: Double(py + (deltaY[id] ?? 0)) / 100)
        }
        return layout
    }

    private static let priorHundredths: [String: (x: Int, y: Int)] = [
        "RINCON_F0F6C1AAD22801400": (24, 24),
        "RINCON_F0F6C1C47CEA01400": (54, 24),
        "RINCON_542A1B95A13A01400": (80, 34),
        "RINCON_542A1B5F088401400": (24, 64),
        "RINCON_542A1B5F08A001400": (54, 64),
        "RINCON_C4387523117601400": (80, 74),
    ]

    private static func pullPercent(_ band: RFPeerMatrix.Band) -> Int? {
        switch band {
        case .strong: 8
        case .moderate: 4
        case .weak: nil
        }
    }

    private static func hundredths(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }
}
