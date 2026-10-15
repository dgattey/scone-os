import CoreGraphics
import Foundation

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

public struct FloorLevel: Hashable, Sendable, Codable, Comparable, Identifiable {
    public let rank: Int
    public let title: String
    public var id: String { "\(rank)-\(title)" }

    public init(rank: Int, title: String) {
        self.rank = rank
        self.title = title
    }

    public static let top = FloorLevel(rank: 2, title: "Top Floor")
    public static let upper = FloorLevel(rank: 1, title: "Upper Floor")
    public static let main = FloorLevel(rank: 0, title: "Main Floor")
    public static let lower = FloorLevel(rank: -1, title: "Lower Floor")

    public static func numbered(_ number: Int) -> FloorLevel {
        FloorLevel(rank: number, title: "Floor \(number)")
    }

    public static func < (lhs: FloorLevel, rhs: FloorLevel) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.title < rhs.title
    }

    public static func classify(roomName: String) -> FloorLevel {
        switch semanticElevationTier(roomName: roomName) {
        case ..<0: return .lower
        case 2...: return .top
        default: return .upper
        }
    }

    public static func semanticElevationTier(roomName: String) -> Int {
        let lowered = roomName.lowercased()
        if let explicitNumber = explicitFloorNumber(in: lowered) {
            return explicitNumber - 1
        }
        let topKeywords = ["penthouse", "attic", "rooftop", "top floor", "third floor", "3rd floor", "level 3"]
        for word in topKeywords where lowered.contains(word) {
            return 2
        }
        let upperKeywords = ["upstairs", "upper", "second floor", "2nd floor", "level 2", "loft"]
        for word in upperKeywords where lowered.contains(word) {
            return 1
        }
        let lowerKeywords = ["basement", "lower", "downstairs", "cellar", "sublevel", "den", "rec", "garage", "patio", "yard"]
        for word in lowerKeywords where lowered.contains(word) {
            return -1
        }
        return 0
    }

    private static func explicitFloorNumber(in lowered: String) -> Int? {
        guard let match = lowered.firstMatch(of: /(?:floor|level)\s*(\d+)/) else {
            return nil
        }
        return Int(match.1)
    }
}

public struct RFPeerMatrix: Hashable, Sendable, Codable {
    public enum Band: Int, Hashable, Sendable, Codable, Comparable {
        case weak = 1, moderate, strong
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var bands: [SpeakerPair: Band]
    private var strengths: [SpeakerPair: Int] = [:]

    public static let empty = RFPeerMatrix(bands: [:])

    private init(bands: [SpeakerPair: Band], strengths: [SpeakerPair: Int] = [:]) {
        self.bands = bands
        self.strengths = strengths
    }

    public func band(_ a: SpeakerUUID, _ b: SpeakerUUID) -> Band? { bands[SpeakerPair(a, b)] }

    public func strength(_ a: SpeakerUUID, _ b: SpeakerUUID) -> Int? {
        strengths[SpeakerPair(a, b)]
    }

    package mutating func record(_ a: SpeakerUUID, _ b: SpeakerUUID, from: Int, to: Int) {
        guard a != b else { return }
        let strength = max(from, to)
        guard strength > 0 else { return }
        let band: Band = if strength >= 35 { .strong } else if strength >= 20 { .moderate } else { .weak }
        let key = SpeakerPair(a, b)
        bands[key] = max(band, bands[key] ?? band)
        strengths[key] = max(strength, strengths[key] ?? strength)
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
    public let level: FloorLevel
    public let coordinate: RoomCoordinate
    public let placement: Placement
    public let group: GroupID?

    package init(
        speaker: Speaker,
        level: FloorLevel,
        coordinate: RoomCoordinate,
        placement: Placement,
        group: GroupID?
    ) {
        self.speaker = speaker
        self.level = level
        self.coordinate = coordinate
        self.placement = placement
        self.group = group
    }
}

public struct FloorplanRoomCluster: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let level: FloorLevel
    public let nodes: [FloorplanNode]

    public init(id: String, title: String, level: FloorLevel, nodes: [FloorplanNode]) {
        self.id = id
        self.title = title
        self.level = level
        self.nodes = nodes
    }

    public var bondedSatellites: [BondedSatellite] {
        nodes.flatMap(\.speaker.bondedSatellites)
    }
}

public struct FloorBandLayout: Identifiable, Hashable, Sendable {
    public var id: FloorLevel { level }
    public let level: FloorLevel
    public let frame: CGRect
    public let safeInnerRect: CGRect
    public let ySpan: ClosedRange<Double>

    public static let cardSize = CGSize(width: 126, height: 92)
    public static let satelliteExtraWidth: CGFloat = 68
    public static let satelliteExtraHeight: CGFloat = 34
    public static let headerHeight: CGFloat = 30

    public func point(for coordinate: RoomCoordinate, hasSatellites: Bool = false) -> CGPoint {
        guard safeInnerRect.width > 0, safeInnerRect.height > 0 else {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let clampedX = min(max(coordinate.x, 0), 1)
        let spanWidth = ySpan.upperBound - ySpan.lowerBound
        let rawLocalY: Double
        if coordinate.y >= ySpan.lowerBound - 0.02 && coordinate.y <= ySpan.upperBound + 0.02 && spanWidth > 0.001 {
            rawLocalY = (coordinate.y - ySpan.lowerBound) / spanWidth
        } else {
            rawLocalY = 0.5
        }
        let clampedY = min(max(rawLocalY, 0), 1)
        let extraHalfX: CGFloat = hasSatellites ? Self.satelliteExtraWidth * 0.5 : 0
        let extraHalfY: CGFloat = hasSatellites ? Self.satelliteExtraHeight * 0.5 : 0
        let effectiveMinX = min(safeInnerRect.midX, safeInnerRect.minX + extraHalfX)
        let effectiveMaxX = max(effectiveMinX, safeInnerRect.maxX - extraHalfX)
        let effectiveWidth = max(0, effectiveMaxX - effectiveMinX)
        let effectiveMaxY = max(safeInnerRect.minY, safeInnerRect.maxY - extraHalfY)
        let effectiveHeight = max(0, effectiveMaxY - safeInnerRect.minY)
        let rawX = effectiveMinX + CGFloat(clampedX) * effectiveWidth
        let rawY = safeInnerRect.minY + CGFloat(clampedY) * effectiveHeight
        return clampPoint(CGPoint(x: rawX, y: rawY), hasSatellites: hasSatellites)
    }

    public func clampPoint(_ point: CGPoint, hasSatellites: Bool = false) -> CGPoint {
        let extraHalfX: CGFloat = hasSatellites ? Self.satelliteExtraWidth * 0.5 : 0
        let extraBottom: CGFloat = hasSatellites ? Self.satelliteExtraHeight * 0.5 : 0
        let minX = min(frame.midX, safeInnerRect.minX + extraHalfX)
        let maxX = max(minX, safeInnerRect.maxX - extraHalfX)
        let minY = min(frame.midY, safeInnerRect.minY)
        let maxY = max(minY, safeInnerRect.maxY - extraBottom)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    public func coordinate(for point: CGPoint, hasSatellites: Bool = false) -> RoomCoordinate {
        let clamped = clampPoint(point, hasSatellites: hasSatellites)
        let extraHalfX: CGFloat = hasSatellites ? Self.satelliteExtraWidth * 0.5 : 0
        let effectiveMinX = min(safeInnerRect.midX, safeInnerRect.minX + extraHalfX)
        let effectiveMaxX = max(effectiveMinX, safeInnerRect.maxX - extraHalfX)
        let effectiveWidth = max(0, effectiveMaxX - effectiveMinX)
        let effectiveMaxY = max(safeInnerRect.minY, safeInnerRect.maxY - (hasSatellites ? Self.satelliteExtraHeight * 0.5 : 0))
        let effectiveHeight = max(0, effectiveMaxY - safeInnerRect.minY)
        let localX = effectiveWidth > 1
            ? Double((clamped.x - effectiveMinX) / effectiveWidth)
            : 0.5
        let localY = effectiveHeight > 1
            ? Double((clamped.y - safeInnerRect.minY) / effectiveHeight)
            : 0.5
        let mappedY = ySpan.lowerBound + min(max(localY, 0), 1) * (ySpan.upperBound - ySpan.lowerBound)
        return RoomCoordinate(clampingX: localX, y: mappedY)
    }

    public static func compute(
        nodes: [FloorplanNode],
        in plot: CGRect,
        activeHubCountByLevel: [FloorLevel: Int] = [:]
    ) -> [FloorBandLayout] {
        guard plot.width > 0, plot.height > 0 else { return [] }
        let distinctLevels = Array(Set(nodes.map(\.level))).sorted(by: >)
        let levels = distinctLevels.isEmpty ? [.main] : distinctLevels
        let floorCount = levels.count
        let interFloorGap: CGFloat = floorCount > 1 ? 14 : 0
        let totalGap = interFloorGap * CGFloat(max(0, floorCount - 1))
        let availableHeight = max(160, plot.height - totalGap)

        let minBandHeights: [CGFloat] = levels.map { level in
            let floorNodes = nodes.filter { $0.level == level }
            let hubCount = activeHubCountByLevel[level] ?? 0
            return requiredBandHeight(
                nodes: floorNodes,
                activeHubCount: hubCount,
                bandWidth: plot.width
            )
        }
        let totalMinHeight = max(minBandHeights.reduce(0, +), 1)
        let extraHeight = max(0, availableHeight - totalMinHeight)

        let halfCardW = cardSize.width * 0.5 + 22

        var result: [FloorBandLayout] = []
        var currentY = plot.minY
        let spans = FloorplanLayout.verticalSpans(forFloorCount: floorCount)

        for (index, level) in levels.enumerated() {
            let share = minBandHeights[index] / totalMinHeight
            let bandHeight = floorCount == 1
                ? max(minBandHeights[index], availableHeight)
                : minBandHeights[index] + extraHeight * share
            let topMargin = headerHeight + cardSize.height * 0.5 + 14
            let bottomMargin = cardSize.height * 0.5 + 14
            let frame = CGRect(x: plot.minX, y: currentY, width: plot.width, height: bandHeight)
            let safeMinX = min(frame.midX, frame.minX + halfCardW)
            let safeMaxX = max(frame.midX, frame.maxX - halfCardW)
            let safeMinY = min(frame.midY + 6, frame.minY + topMargin)
            let safeMaxY = max(safeMinY, frame.maxY - bottomMargin)
            let safeRect = CGRect(
                x: safeMinX,
                y: safeMinY,
                width: max(0, safeMaxX - safeMinX),
                height: max(0, safeMaxY - safeMinY)
            )
            let intSpan = spans[index]
            let doubleSpan = (Double(intSpan.lowerBound) / 100.0)...(Double(intSpan.upperBound) / 100.0)
            result.append(FloorBandLayout(level: level, frame: frame, safeInnerRect: safeRect, ySpan: doubleSpan))
            currentY += bandHeight + interFloorGap
        }
        return result
    }

    public static func requiredBandHeight(
        nodes: [FloorplanNode],
        activeHubCount: Int,
        bandWidth: CGFloat
    ) -> CGFloat {
        let count = nodes.count
        guard count > 0 || activeHubCount > 0 else { return 154 }

        let usableW = max(320, bandWidth - 40)
        let avgRoomW: CGFloat = 166
        let minGapX: CGFloat = 24
        let minGapY: CGFloat = 24
        let maxRoomCols = max(1, Int((usableW + minGapX) / (avgRoomW + minGapX)))
        let hasSatellites = nodes.contains { !$0.speaker.bondedSatellites.isEmpty }
        let maxRowH: CGFloat = hasSatellites ? 128 : 98

        let topPad: CGFloat = 44
        let bottomPad: CGFloat = 22

        if activeHubCount > 0 {
            let hubW: CGFloat = 340
            let hubH: CGFloat = 108
            // Try fitting hub alongside some rooms on the first row
            let remainingForHubRow = usableW - hubW - minGapX
            let roomsAlongsideHub = max(0, min(count, Int((remainingForHubRow + minGapX) / (avgRoomW + minGapX))))
            let remainingRooms = max(0, count - roomsAlongsideHub)
            let extraRoomRows = remainingRooms == 0 ? 0 : (remainingRooms + maxRoomCols - 1) / maxRoomCols
            let totalRows = 1 + extraRoomRows
            let row0H = max(hubH, roomsAlongsideHub > 0 ? maxRowH : hubH)
            let otherRowsH = CGFloat(extraRoomRows) * maxRowH
            let gapsH = CGFloat(max(0, totalRows - 1)) * minGapY
            return topPad + row0H + otherRowsH + gapsH + bottomPad
        } else {
            let rows = max(1, (count + maxRoomCols - 1) / maxRoomCols)
            let firstRowH: CGFloat = hasSatellites ? 128 : 98
            let otherRowsH = CGFloat(max(0, rows - 1)) * 98
            let gapsH = CGFloat(max(0, rows - 1)) * minGapY
            return topPad + firstRowH + otherRowsH + gapsH + bottomPad
        }
    }
}

public enum FloorplanLayout {
    public static func classifyFloors(speakers: [Speaker], matrix: RFPeerMatrix) -> [SpeakerUUID: FloorLevel] {
        guard !speakers.isEmpty else { return [:] }
        var tiers: [SpeakerUUID: Int] = [:]
        for speaker in speakers {
            tiers[speaker.id] = FloorLevel.semanticElevationTier(roomName: speaker.roomName)
        }

        let uniqueTiers = Set(tiers.values).sorted(by: >)
        if uniqueTiers.count == 1, speakers.count >= 4 {
            let rfClusters = verticalRFClusters(speakers: speakers, matrix: matrix)
            if rfClusters.count > 1 {
                let total = rfClusters.count
                var assigned: [SpeakerUUID: FloorLevel] = [:]
                for (index, cluster) in rfClusters.enumerated() {
                    let level = floorLevel(forIndexFromTop: index, totalFloors: total, highestTier: total - 1, lowestTier: 0)
                    for id in cluster {
                        assigned[id] = level
                    }
                }
                return assigned
            }
        }

        let total = uniqueTiers.count
        let highest = uniqueTiers.first ?? 0
        let lowest = uniqueTiers.last ?? 0
        var assigned: [SpeakerUUID: FloorLevel] = [:]
        for speaker in speakers {
            let tier = tiers[speaker.id] ?? 0
            let indexFromTop = uniqueTiers.firstIndex(of: tier) ?? 0
            assigned[speaker.id] = floorLevel(
                forIndexFromTop: indexFromTop,
                totalFloors: total,
                highestTier: highest,
                lowestTier: lowest
            )
        }
        return assigned
    }

    private static func floorLevel(
        forIndexFromTop index: Int,
        totalFloors: Int,
        highestTier: Int,
        lowestTier: Int
    ) -> FloorLevel {
        switch totalFloors {
        case 1:
            if lowestTier < 0 { return .lower }
            if highestTier > 0 { return .upper }
            return .main
        case 2:
            return index == 0 ? .upper : .lower
        case 3:
            switch index {
            case 0: return .upper
            case 1: return .main
            default: return .lower
            }
        default:
            let floorNumber = totalFloors - index
            return .numbered(floorNumber)
        }
    }

    private static func verticalRFClusters(speakers: [Speaker], matrix: RFPeerMatrix) -> [[SpeakerUUID]] {
        let ids = speakers.map(\.id).sorted()
        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func find(_ x: SpeakerUUID) -> SpeakerUUID {
            var root = x
            while let next = parent[root], next != root { root = next }
            return root
        }
        func unite(_ a: SpeakerUUID, _ b: SpeakerUUID) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb {
                if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
            }
        }

        var hasStrongOrModerateEdge: Set<SpeakerUUID> = []
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                if let band = matrix.band(ids[i], ids[j]), band >= .moderate {
                    unite(ids[i], ids[j])
                    hasStrongOrModerateEdge.insert(ids[i])
                    hasStrongOrModerateEdge.insert(ids[j])
                }
            }
        }

        guard hasStrongOrModerateEdge.count == ids.count else { return [ids] }
        var grouped: [SpeakerUUID: [SpeakerUUID]] = [:]
        for id in ids {
            grouped[find(id), default: []].append(id)
        }
        let components = grouped.values.sorted { ($0.first ?? SpeakerUUID(rawValue: "RINCON_00000000000001400")!) < ($1.first ?? SpeakerUUID(rawValue: "RINCON_00000000000001400")!) }
        guard components.count >= 2, components.allSatisfy({ $0.count >= 2 }) else { return [ids] }

        for c1 in components.indices {
            for c2 in (c1 + 1)..<components.count {
                let hasWeakBridge = components[c1].contains { a in
                    components[c2].contains { b in matrix.band(a, b) == .weak }
                }
                if !hasWeakBridge { return [ids] }
            }
        }
        return components
    }

    public static func clusterRooms(nodes: [FloorplanNode], matrix: RFPeerMatrix) -> [FloorplanRoomCluster] {
        guard !nodes.isEmpty else { return [] }
        let levels = Array(Set(nodes.map(\.level))).sorted(by: >)
        var allClusters: [FloorplanRoomCluster] = []

        for level in levels {
            let floorNodes = nodes.filter { $0.level == level }.sorted {
                if abs($0.coordinate.y - $1.coordinate.y) > 0.12 {
                    return $0.coordinate.y < $1.coordinate.y
                }
                if abs($0.coordinate.x - $1.coordinate.x) > 0.04 {
                    return $0.coordinate.x < $1.coordinate.x
                }
                return $0.id < $1.id
            }

            var visited = Set<SpeakerUUID>()
            for node in floorNodes where !visited.contains(node.id) {
                var members = [node]
                visited.insert(node.id)
                let baseName = RoomNaming.shortName(node.speaker.roomName, merged: false)

                for candidate in floorNodes where !visited.contains(candidate.id) {
                    let candidateName = RoomNaming.shortName(candidate.speaker.roomName, merged: false)
                    let sameCanonicalRoom = baseName.caseInsensitiveCompare(candidateName) == .orderedSame
                    let distance = hypot(
                        node.coordinate.x - candidate.coordinate.x,
                        node.coordinate.y - candidate.coordinate.y
                    )
                    let veryCloseRF = (matrix.strength(node.id, candidate.id) ?? 0) >= 52
                    if sameCanonicalRoom || (veryCloseRF && distance <= 0.22) {
                        members.append(candidate)
                        visited.insert(candidate.id)
                    }
                }

                let clusterID = "\(level.rank)-\(members.map(\.id.rawValue).joined(separator: "+"))"
                allClusters.append(
                    FloorplanRoomCluster(
                        id: clusterID,
                        title: baseName,
                        level: level,
                        nodes: members
                    )
                )
            }
        }
        return allClusters
    }

    public static func verticalSpans(forFloorCount count: Int) -> [ClosedRange<Int>] {
        switch count {
        case 0, 1:
            return [20...80]
        case 2:
            return [14...60, 74...88]
        case 3:
            return [12...34, 44...64, 76...90]
        default:
            let step = max(12, 80 / count)
            return (0..<count).map { idx in
                let start = 10 + idx * step
                let end = min(92, start + step - 6)
                return start...max(start, end)
            }
        }
    }

    public static func infer(speakers: [Speaker], matrix: RFPeerMatrix) -> [SpeakerUUID: RoomCoordinate] {
        guard !speakers.isEmpty else { return [:] }
        var byID: [SpeakerUUID: Speaker] = [:]
        for speaker in speakers {
            byID[speaker.id] = speaker
        }
        let unique = byID.values.sorted {
            let lhs = RoomNaming.shortName($0.roomName, merged: false)
            let rhs = RoomNaming.shortName($1.roomName, merged: false)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }

        let floorMap = classifyFloors(speakers: unique, matrix: matrix)
        let distinctLevels = Array(Set(floorMap.values)).sorted(by: >)
        let spans = verticalSpans(forFloorCount: distinctLevels.count)

        var x: [SpeakerUUID: Int] = [:]
        var y: [SpeakerUUID: Int] = [:]

        for (index, level) in distinctLevels.enumerated() {
            let floorSpeakers = unique.filter { floorMap[$0.id] == level }
            seedLevel(floorSpeakers, in: spans[index], matrix: matrix, x: &x, y: &y)
        }

        let ordered = unique.map(\.id)
        var deltaX: [SpeakerUUID: Int] = [:]
        var deltaY: [SpeakerUUID: Int] = [:]
        for left in ordered.indices {
            for right in (left + 1)..<ordered.count {
                let a = ordered[left]
                let b = ordered[right]
                guard let band = matrix.band(a, b), let pull = pullPercent(band),
                      let ax = x[a], let ay = y[a], let bx = x[b], let by = y[b] else { continue }
                let sameLevel = floorMap[a] == floorMap[b]
                let dx = Int((Double(bx - ax) * Double(pull) / 100).rounded())
                let dy = sameLevel ? Int((Double(by - ay) * Double(pull) / 100).rounded()) : 0
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

    private static func seedLevel(
        _ speakers: [Speaker],
        in ySpan: ClosedRange<Int>,
        matrix: RFPeerMatrix,
        x: inout [SpeakerUUID: Int],
        y: inout [SpeakerUUID: Int]
    ) {
        guard !speakers.isEmpty else { return }
        let ordered = chainByRFAndZone(speakers, matrix: matrix)
        let count = ordered.count
        let columns = count <= 3 ? count : Int(Double(count).squareRoot().rounded(.up))
        let rows = max(1, (count + columns - 1) / columns)

        for (index, speaker) in ordered.enumerated() {
            let row = index / columns
            let col = index % columns
            let itemsInRow = row == rows - 1 ? (count - row * columns) : columns
            let xFraction = itemsInRow == 1
                ? 0.50
                : 0.20 + (0.60 * Double(col) / Double(itemsInRow - 1))
            let yFraction = rows == 1
                ? 0.50
                : Double(row) / Double(rows - 1)
            let yValue = Double(ySpan.lowerBound) + yFraction * Double(ySpan.upperBound - ySpan.lowerBound)
            x[speaker.id] = Int((xFraction * 100).rounded())
            y[speaker.id] = Int(yValue.rounded())
        }
    }

    private static func chainByRFAndZone(_ speakers: [Speaker], matrix: RFPeerMatrix) -> [Speaker] {
        var remaining = speakers.sorted {
            let lhsRank = semanticWingRank($0.roomName)
            let rhsRank = semanticWingRank($1.roomName)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsName = RoomNaming.shortName($0.roomName, merged: false)
            let rhsName = RoomNaming.shortName($1.roomName, merged: false)
            return lhsName == rhsName ? $0.id < $1.id : lhsName < rhsName
        }
        guard var current = remaining.first else { return [] }
        remaining.removeFirst()
        var chain = [current]
        while !remaining.isEmpty {
            if let bestIndex = remaining.indices.max(by: { lhs, rhs in
                let bandL = matrix.band(current.id, remaining[lhs].id)?.rawValue ?? 0
                let bandR = matrix.band(current.id, remaining[rhs].id)?.rawValue ?? 0
                if bandL != bandR { return bandL < bandR }
                return lhs > rhs
            }), (matrix.band(current.id, remaining[bestIndex].id)?.rawValue ?? 0) >= RFPeerMatrix.Band.moderate.rawValue {
                current = remaining.remove(at: bestIndex)
            } else {
                current = remaining.removeFirst()
            }
            chain.append(current)
        }
        return chain
    }

    private static func semanticWingRank(_ roomName: String) -> Int {
        let lower = roomName.lowercased()
        if lower.contains("kitchen") || lower.contains("dining") || lower.contains("living") || lower.contains("family") || lower.contains("great") {
            return 0
        }
        if lower.contains("bed") || lower.contains("guest") || lower.contains("nursery") || lower.contains("office") || lower.contains("study") {
            return 1
        }
        return 2
    }

    private static func pullPercent(_ band: RFPeerMatrix.Band) -> Int? {
        switch band {
        case .strong: 8
        case .moderate: 4
        case .weak: nil
        }
    }
}

public struct AcousticCurveSegment: Hashable, Sendable {
    public let start: CGPoint
    public let control: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, control: CGPoint, end: CGPoint) {
        self.start = start
        self.control = control
        self.end = end
    }

    public func point(at t: CGFloat) -> CGPoint {
        let u = 1.0 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    public var midpoint: CGPoint {
        point(at: 0.5)
    }
}

public enum MapDropTarget: Hashable, Sendable {
    case speaker(SpeakerUUID)
    case musicHub(GroupID)
}

package enum FloorplanDragHitTesting {
    package static let defaultDropRadius: CGFloat = 96

    package static func nearestTarget(
        to point: CGPoint,
        excluding draggedID: SpeakerUUID,
        draggedGroup: GroupID?,
        displayPoints: [SpeakerUUID: CGPoint],
        hubLocations: [GroupID: CGPoint],
        dropRadius: CGFloat = defaultDropRadius
    ) -> MapDropTarget? {
        var best: MapDropTarget?
        var bestDistance = dropRadius

        for (groupID, hubCenter) in hubLocations where groupID != draggedGroup {
            let distance = hypot(hubCenter.x - point.x, hubCenter.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = .musicHub(groupID)
            }
        }
        for (speakerID, center) in displayPoints where speakerID != draggedID {
            let distance = hypot(center.x - point.x, center.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = .speaker(speakerID)
            }
        }
        return best
    }
}

public enum AcousticCurveRouter {
    public static func nodeObstacleRect(center: CGPoint, hasSatellites: Bool = false) -> CGRect {
        let width: CGFloat = hasSatellites ? 198 : 142
        let height: CGFloat = hasSatellites ? 128 : 98
        return CGRect(
            x: center.x - width * 0.5,
            y: center.y - height * 0.5,
            width: width,
            height: height
        )
    }

    public static func musicHubSize() -> CGSize {
        CGSize(width: 340, height: 108)
    }

    public static func musicHubRect(center: CGPoint) -> CGRect {
        let size = musicHubSize()
        return CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }

    /// Clips a quadratic Bezier segment so it starts cleanly at the edge of `startRect`
    /// and terminates cleanly at the edge of `endRect` rather than running to the centers,
    /// while re-centering the control point on the clipped chord so short gaps never hook.
    public static func clippedSegment(
        _ segment: AcousticCurveSegment,
        startRect: CGRect,
        endRect: CGRect,
        inset: CGFloat = 2
    ) -> AcousticCurveSegment {
        let paddedStart = startRect.insetBy(dx: -inset, dy: -inset)
        let paddedEnd = endRect.insetBy(dx: -inset, dy: -inset)
        let clippedStart = firstPointOutside(segment, rect: paddedStart, fromStart: true)
        let clippedEnd = firstPointOutside(segment, rect: paddedEnd, fromStart: false)

        let origDX = segment.end.x - segment.start.x
        let origDY = segment.end.y - segment.start.y
        let origLen = max(hypot(origDX, origDY), 1)
        let origMid = CGPoint(x: (segment.start.x + segment.end.x) * 0.5, y: (segment.start.y + segment.end.y) * 0.5)
        let origPerp = (segment.control.x - origMid.x) * (-origDY / origLen)
            + (segment.control.y - origMid.y) * (origDX / origLen)

        let newDX = clippedEnd.x - clippedStart.x
        let newDY = clippedEnd.y - clippedStart.y
        let newLen = hypot(newDX, newDY)
        let newMid = CGPoint(x: (clippedStart.x + clippedEnd.x) * 0.5, y: (clippedStart.y + clippedEnd.y) * 0.5)
        guard newLen > 2 else {
            return AcousticCurveSegment(start: clippedStart, control: newMid, end: clippedEnd)
        }
        let nx = -newDY / newLen
        let ny = newDX / newLen
        let scaledBow = origPerp * (newLen / origLen)
        let maxBow = newLen < 160 ? min(26, newLen * 0.14) : min(96, newLen * 0.28)
        let clampedBow = min(max(scaledBow, -maxBow), maxBow)
        let newControl = CGPoint(x: newMid.x + nx * clampedBow, y: newMid.y + ny * clampedBow)
        return AcousticCurveSegment(start: clippedStart, control: newControl, end: clippedEnd)
    }

    /// Routes a tether directly between the outer boundary of `startRect` and the outer boundary
    /// of `endRect` so the control point is computed after boundary clipping and never hooks.
    public static func routeTether(
        startRect: CGRect,
        endRect: CGRect,
        obstacles: [CGRect],
        bounds: CGRect? = nil,
        inset: CGFloat = 2
    ) -> AcousticCurveSegment {
        let paddedStart = startRect.insetBy(dx: -inset, dy: -inset)
        let paddedEnd = endRect.insetBy(dx: -inset, dy: -inset)
        let startCenter = CGPoint(x: startRect.midX, y: startRect.midY)
        let endCenter = CGPoint(x: endRect.midX, y: endRect.midY)
        let startPt = rayRectExit(origin: startCenter, toward: endCenter, rect: paddedStart, clampToSegment: false)
        let endPt = rayRectExit(origin: endCenter, toward: startCenter, rect: paddedEnd, clampToSegment: false)

        let otherObstacles = obstacles.filter { rect in
            !rect.intersects(startRect.insetBy(dx: 4, dy: 4)) && !rect.intersects(endRect.insetBy(dx: 4, dy: 4))
        }
        return routeSegment(
            start: startPt,
            end: endPt,
            obstacles: otherObstacles,
            bounds: bounds,
            padding: 14
        )
    }

    private static func firstPointOutside(
        _ segment: AcousticCurveSegment,
        rect: CGRect,
        fromStart: Bool
    ) -> CGPoint {
        let origin = fromStart ? segment.start : segment.end
        let farEnd = fromStart ? segment.end : segment.start
        guard rect.contains(origin) else { return origin }

        // If the entire curve or far endpoint is inside the rect, project radially to the boundary.
        if rect.contains(farEnd) {
            return rayRectExit(origin: origin, toward: farEnd, rect: rect, clampToSegment: false)
        }

        // Binary-search along the actual quadratic Bezier curve to find the exact parameter t where
        // the curve exits `rect`.
        var lo: CGFloat = 0.0
        var hi: CGFloat = 1.0
        let sampleSteps = 32
        for i in 1...sampleSteps {
            let u = CGFloat(i) / CGFloat(sampleSteps)
            let t = fromStart ? u : (1.0 - u)
            if !rect.contains(segment.point(at: t)) {
                hi = u
                lo = CGFloat(i - 1) / CGFloat(sampleSteps)
                break
            }
        }
        for _ in 0..<14 {
            let mid = (lo + hi) * 0.5
            let t = fromStart ? mid : (1.0 - mid)
            if rect.contains(segment.point(at: t)) {
                lo = mid
            } else {
                hi = mid
            }
        }
        let exitT = fromStart ? hi : (1.0 - hi)
        return segment.point(at: exitT)
    }

    private static func rayRectExit(
        origin: CGPoint,
        toward target: CGPoint,
        rect: CGRect,
        clampToSegment: Bool = true
    ) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        guard abs(dx) > 1e-4 || abs(dy) > 1e-4 else {
            return CGPoint(x: origin.x, y: rect.minY)
        }
        var bestT = CGFloat.greatestFiniteMagnitude
        if abs(dx) > 1e-4 {
            let tLeft = (rect.minX - origin.x) / dx
            if tLeft > 0 { bestT = min(bestT, tLeft) }
            let tRight = (rect.maxX - origin.x) / dx
            if tRight > 0 { bestT = min(bestT, tRight) }
        }
        if abs(dy) > 1e-4 {
            let tTop = (rect.minY - origin.y) / dy
            if tTop > 0 { bestT = min(bestT, tTop) }
            let tBottom = (rect.maxY - origin.y) / dy
            if tBottom > 0 { bestT = min(bestT, tBottom) }
        }
        guard bestT.isFinite, (!clampToSegment || bestT <= 1.0) else { return origin }
        return CGPoint(x: origin.x + dx * bestT, y: origin.y + dy * bestT)
    }

    /// Computes a coherent, collision-free position for a Music Square hub connected to `speakerPoints`
    /// inside `bounds`, avoiding all room container rects in `roomObstacles`.
    public static func placeMusicHub(
        connectedPoints: [CGPoint],
        roomObstacles: [CGRect],
        existingHubs: [CGRect] = [],
        bounds: CGRect
    ) -> CGPoint {
        guard !connectedPoints.isEmpty else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let hubSize = musicHubSize()
        let safeBounds = bounds.insetBy(
            dx: min(bounds.width * 0.4, hubSize.width * 0.5 + 16),
            dy: min(bounds.height * 0.4, hubSize.height * 0.5 + 14)
        )

        let rawCentroid: CGPoint
        if connectedPoints.count == 1 {
            let p = connectedPoints[0]
            let offsetY: CGFloat = (p.y - safeBounds.minY > safeBounds.maxY - p.y) ? -144 : 144
            rawCentroid = CGPoint(x: p.x, y: p.y + offsetY)
        } else {
            let sumX = connectedPoints.reduce(0.0) { $0 + $1.x }
            let sumY = connectedPoints.reduce(0.0) { $0 + $1.y }
            let cx = sumX / CGFloat(connectedPoints.count)
            let cy = sumY / CGFloat(connectedPoints.count)
            let ySpan = (connectedPoints.map(\.y).max() ?? cy) - (connectedPoints.map(\.y).min() ?? cy)
            if ySpan < 36 {
                let spaceBelow = safeBounds.maxY - cy
                let spaceAbove = cy - safeBounds.minY
                let shiftY: CGFloat = spaceBelow >= spaceAbove ? min(92, spaceBelow * 0.72) : -min(92, spaceAbove * 0.72)
                rawCentroid = CGPoint(x: cx, y: cy + shiftY)
            } else {
                rawCentroid = CGPoint(x: cx, y: cy)
            }
        }

        func clampToSafe(_ pt: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(pt.x, safeBounds.minX), safeBounds.maxX),
                y: min(max(pt.y, safeBounds.minY), safeBounds.maxY)
            )
        }

        let paddedObstacles = roomObstacles.map { $0.insetBy(dx: -20, dy: -22) }
            + existingHubs.map { $0.insetBy(dx: -24, dy: -22) }

        func hubClearance(at center: CGPoint) -> CGFloat {
            let rect = musicHubRect(center: center)
            var minClearance = CGFloat.greatestFiniteMagnitude
            for obs in paddedObstacles {
                let dx = max(obs.minX - rect.maxX, 0, rect.minX - obs.maxX)
                let dy = max(obs.minY - rect.maxY, 0, rect.minY - obs.maxY)
                let dist: CGFloat
                if dx > 0 || dy > 0 {
                    dist = hypot(dx, dy)
                } else {
                    let overlapX = min(rect.maxX - obs.minX, obs.maxX - rect.minX)
                    let overlapY = min(rect.maxY - obs.minY, obs.maxY - rect.minY)
                    dist = -min(overlapX, overlapY)
                }
                if dist < minClearance {
                    minClearance = dist
                }
            }
            return minClearance
        }

        let base = clampToSafe(rawCentroid)
        if hubClearance(at: base) >= 16 {
            return base
        }

        var bestPoint = base
        var bestScore = -CGFloat.greatestFiniteMagnitude

        func evaluate(_ candidate: CGPoint) {
            let clamped = clampToSafe(candidate)
            let clearance = hubClearance(at: clamped)
            let distFromCentroid = hypot(clamped.x - base.x, clamped.y - base.y)
            let score = (clearance >= 0 ? 1200.0 + min(clearance, 48.0) * 2.5 : clearance * 16.0) - distFromCentroid * 0.24
            if score > bestScore {
                bestScore = score
                bestPoint = clamped
            }
        }

        evaluate(base)
        let radii: [CGFloat] = [28, 52, 78, 106, 138, 174, 214, 256, 300]
        let angles = 24
        for r in radii {
            for a in 0..<angles {
                let theta = (Double(a) / Double(angles)) * 2.0 * Double.pi
                evaluate(
                    CGPoint(
                        x: base.x + CGFloat(cos(theta)) * r,
                        y: base.y + CGFloat(sin(theta)) * r
                    )
                )
            }
        }

        let gridCols = 9
        let gridRows = 5
        for gx in 0..<gridCols {
            let fx = CGFloat(gx) / CGFloat(gridCols - 1)
            for gy in 0..<gridRows {
                let fy = CGFloat(gy) / CGFloat(gridRows - 1)
                evaluate(
                    CGPoint(
                        x: safeBounds.minX + fx * safeBounds.width,
                        y: safeBounds.minY + fy * safeBounds.height
                    )
                )
            }
        }
        return bestPoint
    }

    public struct LayoutRoomSpec: Sendable {
        public let id: SpeakerUUID
        public var center: CGPoint
        public let hasSatellites: Bool
        public let isFixed: Bool

        public init(id: SpeakerUUID, center: CGPoint, hasSatellites: Bool, isFixed: Bool) {
            self.id = id
            self.center = center
            self.hasSatellites = hasSatellites
            self.isFixed = isFixed
        }
    }

    /// Resolves 2D rectangle collisions between Music Hub cards and room containers within `bandFrame`
    /// with a guaranteed non-overlapping solver enforcing >=24pt horizontal and >=24pt vertical gaps
    /// and strict containment inside `bandFrame` inset by >=20pt.
    public static func resolveBandCollisions(
        rooms: [LayoutRoomSpec],
        hubCenters: [GroupID: CGPoint],
        bandFrame: CGRect
    ) -> (roomCenters: [SpeakerUUID: CGPoint], hubCenters: [GroupID: CGPoint]) {
        var mutableRooms = rooms
        var mutableHubs = hubCenters
        let hubIDs = hubCenters.keys.sorted()

        let edgeInset: CGFloat = 20
        let minTopOffset: CGFloat = max(edgeInset, FloorBandLayout.headerHeight + 12)
        let minGapX: CGFloat = 24
        let minGapY: CGFloat = 24

        func clampRectCenter(_ pt: CGPoint, size: CGSize) -> CGPoint {
            let halfW = size.width * 0.5 + edgeInset
            let minX = min(bandFrame.midX, bandFrame.minX + halfW)
            let maxX = max(minX, bandFrame.maxX - halfW)
            let minY = min(bandFrame.midY, bandFrame.minY + minTopOffset + size.height * 0.5)
            let maxY = max(minY, bandFrame.maxY - edgeInset - size.height * 0.5)
            return CGPoint(
                x: min(max(pt.x, minX), maxX),
                y: min(max(pt.y, minY), maxY)
            )
        }

        func clampRoom(_ pt: CGPoint, hasSatellites: Bool) -> CGPoint {
            let size = nodeObstacleRect(center: .zero, hasSatellites: hasSatellites).size
            return clampRectCenter(pt, size: size)
        }

        func clampHub(_ pt: CGPoint) -> CGPoint {
            return clampRectCenter(pt, size: musicHubSize())
        }

        for rIdx in mutableRooms.indices where !mutableRooms[rIdx].isFixed {
            mutableRooms[rIdx].center = clampRoom(mutableRooms[rIdx].center, hasSatellites: mutableRooms[rIdx].hasSatellites)
        }
        for hID in hubIDs {
            if let c = mutableHubs[hID] {
                mutableHubs[hID] = clampHub(c)
            }
        }

        // Break any exact or near-identical room centers deterministically before relaxation
        if mutableRooms.count > 1 {
            for i in 0..<(mutableRooms.count - 1) {
                for j in (i + 1)..<mutableRooms.count {
                    let a = mutableRooms[i]
                    let b = mutableRooms[j]
                    if hypot(a.center.x - b.center.x, a.center.y - b.center.y) < 12 {
                        let sign: CGFloat = a.id < b.id ? -1 : 1
                        if !a.isFixed {
                            mutableRooms[i].center = clampRoom(
                                CGPoint(x: a.center.x + sign * 42, y: a.center.y),
                                hasSatellites: a.hasSatellites
                            )
                        }
                        if !b.isFixed {
                            mutableRooms[j].center = clampRoom(
                                CGPoint(x: b.center.x - sign * 42, y: b.center.y),
                                hasSatellites: b.hasSatellites
                            )
                        }
                    }
                }
            }
        }

        for _ in 0..<48 {
            var hadOverlap = false

            // 1. Separate Music Hubs from each other
            if hubIDs.count > 1 {
                for i in 0..<(hubIDs.count - 1) {
                    for j in (i + 1)..<hubIDs.count {
                        let idA = hubIDs[i]
                        let idB = hubIDs[j]
                        guard let cA = mutableHubs[idA], let cB = mutableHubs[idB] else { continue }
                        let rA = musicHubRect(center: cA).insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                        let rB = musicHubRect(center: cB).insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                        guard rA.intersects(rB) else { continue }
                        hadOverlap = true
                        let ox = min(rA.maxX - rB.minX, rB.maxX - rA.minX)
                        let oy = min(rA.maxY - rB.minY, rB.maxY - rA.minY)
                        let dirX: CGFloat = cB.x >= cA.x ? 1 : -1
                        let dirY: CGFloat = cB.y >= cA.y ? 1 : -1
                        if ox <= oy {
                            mutableHubs[idA] = clampHub(CGPoint(x: cA.x - dirX * (ox * 0.55 + 2), y: cA.y))
                            mutableHubs[idB] = clampHub(CGPoint(x: cB.x + dirX * (ox * 0.55 + 2), y: cB.y))
                        } else {
                            mutableHubs[idA] = clampHub(CGPoint(x: cA.x, y: cA.y - dirY * (oy * 0.55 + 2)))
                            mutableHubs[idB] = clampHub(CGPoint(x: cB.x, y: cB.y + dirY * (oy * 0.55 + 2)))
                        }
                    }
                }
            }

            // 2. Separate Music Hubs from Room cards
            for hID in hubIDs {
                guard var hCenter = mutableHubs[hID] else { continue }
                for rIdx in mutableRooms.indices {
                    let rSpec = mutableRooms[rIdx]
                    let hRect = musicHubRect(center: hCenter).insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                    let rRect = nodeObstacleRect(center: rSpec.center, hasSatellites: rSpec.hasSatellites)
                        .insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                    guard hRect.intersects(rRect) else { continue }
                    hadOverlap = true

                    let overlapX = min(hRect.maxX - rRect.minX, rRect.maxX - hRect.minX)
                    let overlapY = min(hRect.maxY - rRect.minY, rRect.maxY - hRect.minY)
                    guard overlapX > 0, overlapY > 0 else { continue }

                    let dirX: CGFloat = rSpec.center.x >= hCenter.x ? 1 : -1
                    let dirY: CGFloat = rSpec.center.y >= hCenter.y ? 1 : -1

                    let testRoomY = clampRoom(
                        CGPoint(x: rSpec.center.x, y: rSpec.center.y + dirY * (overlapY + 4)),
                        hasSatellites: rSpec.hasSatellites
                    )
                    let testHubY = clampHub(
                        CGPoint(x: hCenter.x, y: hCenter.y - dirY * (overlapY * 0.45))
                    )
                    let achievedVerticalSep = abs(testRoomY.y - rSpec.center.y) + abs(testHubY.y - hCenter.y)

                    if overlapY <= overlapX && achievedVerticalSep >= overlapY * 0.85 {
                        if !rSpec.isFixed {
                            mutableRooms[rIdx].center = clampRoom(
                                CGPoint(x: rSpec.center.x, y: rSpec.center.y + dirY * (overlapY * 0.72 + 2)),
                                hasSatellites: rSpec.hasSatellites
                            )
                        }
                        hCenter = clampHub(CGPoint(x: hCenter.x, y: hCenter.y - dirY * (overlapY * 0.36 + 1)))
                    } else {
                        let xDir: CGFloat
                        if abs(rSpec.center.x - hCenter.x) < 16 {
                            let spaceLeft = hCenter.x - bandFrame.minX
                            let spaceRight = bandFrame.maxX - hCenter.x
                            xDir = spaceRight >= spaceLeft ? 1 : -1
                        } else {
                            xDir = dirX
                        }
                        if !rSpec.isFixed {
                            mutableRooms[rIdx].center = clampRoom(
                                CGPoint(
                                    x: rSpec.center.x + xDir * (overlapX * 0.72 + 2),
                                    y: rSpec.center.y + dirY * min(overlapY * 0.45, 22)
                                ),
                                hasSatellites: rSpec.hasSatellites
                            )
                        }
                        hCenter = clampHub(
                            CGPoint(
                                x: hCenter.x - xDir * (overlapX * 0.32 + 1),
                                y: hCenter.y - dirY * min(overlapY * 0.25, 12)
                            )
                        )
                    }
                    mutableHubs[hID] = hCenter
                }
            }

            // 3. Separate Room cards from each other
            if mutableRooms.count > 1 {
                for i in 0..<(mutableRooms.count - 1) {
                    for j in (i + 1)..<mutableRooms.count {
                        let a = mutableRooms[i]
                        let b = mutableRooms[j]
                        let rectA = nodeObstacleRect(center: a.center, hasSatellites: a.hasSatellites)
                            .insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                        let rectB = nodeObstacleRect(center: b.center, hasSatellites: b.hasSatellites)
                            .insetBy(dx: -minGapX * 0.5, dy: -minGapY * 0.5)
                        guard rectA.intersects(rectB) else { continue }
                        hadOverlap = true

                        let overlapX = min(rectA.maxX - rectB.minX, rectB.maxX - rectA.minX)
                        let overlapY = min(rectA.maxY - rectB.minY, rectB.maxY - rectA.minY)
                        guard overlapX > 0, overlapY > 0 else { continue }

                        let dirX: CGFloat = (abs(b.center.x - a.center.x) < 2)
                            ? (a.id < b.id ? 1 : -1)
                            : (b.center.x >= a.center.x ? 1 : -1)
                        let dirY: CGFloat = (abs(b.center.y - a.center.y) < 2)
                            ? (a.id < b.id ? 1 : -1)
                            : (b.center.y >= a.center.y ? 1 : -1)

                        let testAX = clampRoom(CGPoint(x: a.center.x - dirX * (overlapX * 0.6 + 2), y: a.center.y), hasSatellites: a.hasSatellites)
                        let testBX = clampRoom(CGPoint(x: b.center.x + dirX * (overlapX * 0.6 + 2), y: b.center.y), hasSatellites: b.hasSatellites)
                        let achievedX = abs(testAX.x - a.center.x) + abs(testBX.x - b.center.x)

                        if overlapX <= overlapY * 1.25 && achievedX >= overlapX * 0.80 {
                            if !a.isFixed { mutableRooms[i].center = testAX }
                            if !b.isFixed { mutableRooms[j].center = testBX }
                        } else {
                            let stepY = overlapY * 0.6 + 2
                            if !a.isFixed {
                                mutableRooms[i].center = clampRoom(
                                    CGPoint(x: a.center.x - dirX * min(overlapX * 0.25, 16), y: a.center.y - dirY * stepY),
                                    hasSatellites: a.hasSatellites
                                )
                            }
                            if !b.isFixed {
                                mutableRooms[j].center = clampRoom(
                                    CGPoint(x: b.center.x + dirX * min(overlapX * 0.25, 16), y: b.center.y + dirY * stepY),
                                    hasSatellites: b.hasSatellites
                                )
                            }
                        }
                    }
                }
            }

            if !hadOverlap { break }
        }

        // If any pair still overlaps within 24pt after force relaxation, run deterministic shelf packing
        if hasAnyBandOverlap(rooms: mutableRooms, hubs: mutableHubs, minGapX: minGapX, minGapY: minGapY, bandFrame: bandFrame, edgeInset: edgeInset) {
            return deterministicShelfPack(
                rooms: mutableRooms,
                hubCenters: mutableHubs,
                bandFrame: bandFrame,
                edgeInset: edgeInset,
                minTopOffset: minTopOffset,
                minGapX: minGapX,
                minGapY: minGapY
            )
        }

        let resolvedRooms = Dictionary(uniqueKeysWithValues: mutableRooms.map { ($0.id, $0.center) })
        return (resolvedRooms, mutableHubs)
    }

    private static func hasAnyBandOverlap(
        rooms: [LayoutRoomSpec],
        hubs: [GroupID: CGPoint],
        minGapX: CGFloat,
        minGapY: CGFloat,
        bandFrame: CGRect,
        edgeInset: CGFloat
    ) -> Bool {
        let safeContainer = bandFrame.insetBy(dx: max(0, edgeInset - 4), dy: max(0, edgeInset - 4))
        let minClearanceX = min(minGapX * 0.25, 6)
        let minClearanceY = min(minGapY * 0.25, 6)
        var allRects: [(rect: CGRect, padded: CGRect)] = []
        for r in rooms {
            let rect = nodeObstacleRect(center: r.center, hasSatellites: r.hasSatellites)
            if !safeContainer.contains(rect) { return true }
            allRects.append((rect, rect.insetBy(dx: -minClearanceX, dy: -minClearanceY)))
        }
        for (_, hCenter) in hubs {
            let rect = musicHubRect(center: hCenter)
            if !safeContainer.contains(rect) { return true }
            allRects.append((rect, rect.insetBy(dx: -minClearanceX, dy: -minClearanceY)))
        }
        guard allRects.count > 1 else { return false }
        for i in 0..<(allRects.count - 1) {
            for j in (i + 1)..<allRects.count {
                if allRects[i].padded.intersects(allRects[j].padded) {
                    return true
                }
            }
        }
        return false
    }

    private static func deterministicShelfPack(
        rooms: [LayoutRoomSpec],
        hubCenters: [GroupID: CGPoint],
        bandFrame: CGRect,
        edgeInset: CGFloat,
        minTopOffset: CGFloat,
        minGapX: CGFloat,
        minGapY: CGFloat
    ) -> (roomCenters: [SpeakerUUID: CGPoint], hubCenters: [GroupID: CGPoint]) {
        enum PackItem {
            case room(LayoutRoomSpec, CGSize)
            case hub(GroupID, CGPoint, CGSize)

            var preferredPoint: CGPoint {
                switch self {
                case .room(let spec, _): spec.center
                case .hub(_, let pt, _): pt
                }
            }
            var size: CGSize {
                switch self {
                case .room(_, let s), .hub(_, _, let s): s
                }
            }
        }

        let safeMinX = bandFrame.minX + edgeInset
        let safeMaxX = bandFrame.maxX - edgeInset
        let safeW = max(200, safeMaxX - safeMinX)
        let safeMinY = bandFrame.minY + minTopOffset
        let safeMaxY = bandFrame.maxY - edgeInset

        let fixedItems = rooms.filter(\.isFixed)
        let movableRooms = rooms.filter { !$0.isFixed }

        // Sort rooms by preferred row (top vs bottom) then X so spatial intent is preserved
        let sortedRooms = movableRooms.sorted { lhs, rhs in
            if abs(lhs.center.y - rhs.center.y) > 48 {
                return lhs.center.y < rhs.center.y
            }
            if abs(lhs.center.x - rhs.center.x) > 8 {
                return lhs.center.x < rhs.center.x
            }
            return lhs.id < rhs.id
        }

        let sortedHubIDs = hubCenters.keys.sorted()
        var items: [PackItem] = []

        // Interleave hubs into their nearest vertical row region while preserving horizontal preference
        var allCandidates: [PackItem] = sortedRooms.map {
            .room($0, nodeObstacleRect(center: .zero, hasSatellites: $0.hasSatellites).size)
        }
        for hID in sortedHubIDs {
            if let pt = hubCenters[hID] {
                allCandidates.append(.hub(hID, pt, musicHubSize()))
            }
        }

        items = allCandidates.sorted { a, b in
            let pa = a.preferredPoint
            let pb = b.preferredPoint
            if abs(pa.y - pb.y) > 54 {
                return pa.y < pb.y
            }
            return pa.x < pb.x
        }

        struct ShelfRow {
            var items: [PackItem] = []
            var totalWidth: CGFloat = 0
            var maxHeight: CGFloat = 0
        }

        var rows: [ShelfRow] = []
        var currentRow = ShelfRow()

        for item in items {
            let w = item.size.width
            let h = item.size.height
            let nextWidth = currentRow.items.isEmpty ? w : (currentRow.totalWidth + minGapX + w)
            if !currentRow.items.isEmpty && nextWidth > safeW {
                rows.append(currentRow)
                currentRow = ShelfRow(items: [item], totalWidth: w, maxHeight: h)
            } else {
                currentRow.items.append(item)
                currentRow.totalWidth = nextWidth
                currentRow.maxHeight = max(currentRow.maxHeight, h)
            }
        }
        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        // Re-sort items within each shelf row strictly by preferred X so left-to-right order is natural
        for rIdx in rows.indices {
            rows[rIdx].items.sort { $0.preferredPoint.x < $1.preferredPoint.x }
        }

        let totalRowsHeight = rows.reduce(CGFloat(0)) { $0 + $1.maxHeight }
            + CGFloat(max(0, rows.count - 1)) * minGapY
        let availableH = max(totalRowsHeight, safeMaxY - safeMinY)
        let extraRowSpace = max(0, availableH - totalRowsHeight)
        let rowGapY = rows.count > 1
            ? minGapY + min(28, extraRowSpace / CGFloat(rows.count))
            : minGapY
        let totalUsedH = rows.reduce(CGFloat(0)) { $0 + $1.maxHeight }
            + CGFloat(max(0, rows.count - 1)) * rowGapY
        var cursorY = safeMinY + max(0, (availableH - totalUsedH) * 0.5)

        var outRooms: [SpeakerUUID: CGPoint] = Dictionary(uniqueKeysWithValues: fixedItems.map { ($0.id, $0.center) })
        var outHubs: [GroupID: CGPoint] = [:]

        for row in rows {
            let rowCenterY = min(
                max(cursorY + row.maxHeight * 0.5, safeMinY + row.maxHeight * 0.5),
                max(safeMinY + row.maxHeight * 0.5, safeMaxY - row.maxHeight * 0.5)
            )
            let count = row.items.count
            let extraW = max(0, safeW - row.totalWidth)
            // Distribute horizontal slack evenly with generous breathing room
            let gapX = count > 1
                ? minGapX + min(56, extraW / CGFloat(count))
                : minGapX
            let rowSpanW = row.items.reduce(CGFloat(0)) { $0 + $1.size.width }
                + CGFloat(max(0, count - 1)) * gapX
            var cursorX = safeMinX + max(0, (safeW - rowSpanW) * 0.5)

            for item in row.items {
                let w = item.size.width
                let centerX = cursorX + w * 0.5
                let pt = CGPoint(x: centerX, y: rowCenterY)
                switch item {
                case .room(let spec, _):
                    outRooms[spec.id] = spec.isFixed ? spec.center : pt
                case .hub(let gID, _, _):
                    outHubs[gID] = pt
                }
                cursorX += w + gapX
            }
            cursorY += row.maxHeight + rowGapY
        }

        return (outRooms, outHubs)
    }

    /// Gently pushes any nearby room container outward if a Music Hub placed at `hubCenter`
    /// is within `minSeparation` of the room center.
    public static func nudgedRoomPoint(
        basePoint: CGPoint,
        hubCenter: CGPoint?,
        safeRect: CGRect,
        minSeparation: CGFloat = 148
    ) -> CGPoint {
        guard let hubCenter else { return basePoint }
        let dx = basePoint.x - hubCenter.x
        let dy = basePoint.y - hubCenter.y
        let dist = hypot(dx, dy)
        guard dist < minSeparation else { return basePoint }
        let push = (minSeparation - dist) * 0.82
        let ux = dist > 1 ? dx / dist : 0
        let uy = dist > 1 ? dy / dist : -1
        let raw = CGPoint(x: basePoint.x + ux * push, y: basePoint.y + uy * push)
        return CGPoint(
            x: min(max(raw.x, safeRect.minX), safeRect.maxX),
            y: min(max(raw.y, safeRect.minY), safeRect.maxY)
        )
    }

    public static func orderedChain(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else {
            return points.sorted {
                if abs($0.x - $1.x) > 8 { return $0.x < $1.x }
                return $0.y < $1.y
            }
        }
        var remaining = points.sorted {
            let score0 = $0.x + $0.y * 0.25
            let score1 = $1.x + $1.y * 0.25
            if abs(score0 - score1) > 1 { return score0 < score1 }
            return $0.x < $1.x
        }
        var chain = [remaining.removeFirst()]
        while !remaining.isEmpty {
            let last = chain[chain.count - 1]
            var bestIndex = 0
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for idx in remaining.indices {
                let d = hypot(remaining[idx].x - last.x, remaining[idx].y - last.y)
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = idx
                }
            }
            chain.append(remaining.remove(at: bestIndex))
        }
        return chain
    }

    public static func routeChain(
        points: [CGPoint],
        obstacles: [CGRect],
        bounds: CGRect? = nil,
        padding: CGFloat = 22
    ) -> [AcousticCurveSegment] {
        let ordered = orderedChain(points)
        guard ordered.count >= 2 else { return [] }
        return (0..<(ordered.count - 1)).map { index in
            routeSegment(
                start: ordered[index],
                end: ordered[index + 1],
                obstacles: obstacles,
                bounds: bounds,
                padding: padding
            )
        }
    }

    public static func routeSegment(
        start: CGPoint,
        end: CGPoint,
        obstacles: [CGRect],
        bounds: CGRect? = nil,
        padding: CGFloat = 22
    ) -> AcousticCurveSegment {
        let nonEndpointObstacles = obstacles.filter { rect in
            let shrunk = rect.insetBy(dx: 4, dy: 4)
            return !shrunk.contains(start) && !shrunk.contains(end)
        }
        let paddedObstacles = nonEndpointObstacles.map { $0.insetBy(dx: -padding, dy: -padding) }

        let mid = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)

        var nx = -dy / length
        var ny = dx / length
        if ny > 0 || (abs(ny) < 1e-5 && nx > 0) {
            nx = -nx
            ny = -ny
        }

        func segment(forBow bow: CGFloat) -> AcousticCurveSegment {
            let control = CGPoint(x: mid.x + nx * bow, y: mid.y + ny * bow)
            return AcousticCurveSegment(start: start, control: control, end: end)
        }

        let defaultBow = min(28, length * 0.12)
        let primaryDefault = segment(forBow: defaultBow)
        let flippedDefault = segment(forBow: -defaultBow)

        if paddedObstacles.isEmpty {
            let primaryMargin = boundsMargin(for: primaryDefault, bounds: bounds)
            let flippedMargin = boundsMargin(for: flippedDefault, bounds: bounds)
            return (primaryMargin >= 0 || primaryMargin >= flippedMargin) ? primaryDefault : flippedDefault
        }

        let primaryClearance = minObstacleClearance(for: primaryDefault, paddedObstacles: paddedObstacles)
        if primaryClearance >= 0, boundsMargin(for: primaryDefault, bounds: bounds) >= 0 {
            return primaryDefault
        }
        let flippedClearance = minObstacleClearance(for: flippedDefault, paddedObstacles: paddedObstacles)
        if flippedClearance >= 0, boundsMargin(for: flippedDefault, bounds: bounds) > boundsMargin(for: primaryDefault, bounds: bounds) {
            return flippedDefault
        }

        struct Candidate {
            let segment: AcousticCurveSegment
            let bowMagnitude: CGFloat
            let clearance: CGFloat
            let boundsMargin: CGFloat
        }

        var clearCandidates: [Candidate] = []
        var bestFallback = Candidate(
            segment: primaryDefault,
            bowMagnitude: defaultBow,
            clearance: primaryClearance,
            boundsMargin: boundsMargin(for: primaryDefault, bounds: bounds)
        )

        for sign: CGFloat in [1.0, -1.0] {
            var foundForSign = false
            var mag = defaultBow
            while mag <= 320 {
                let seg = segment(forBow: sign * mag)
                let clearance = minObstacleClearance(for: seg, paddedObstacles: paddedObstacles)
                let bMargin = boundsMargin(for: seg, bounds: bounds)
                let cand = Candidate(segment: seg, bowMagnitude: mag, clearance: clearance, boundsMargin: bMargin)
                if clearance > bestFallback.clearance {
                    bestFallback = cand
                }
                if clearance >= 0, !foundForSign {
                    let bufferedMag = min(320, mag + 12)
                    let bufferedSeg = segment(forBow: sign * bufferedMag)
                    let bufferedClearance = minObstacleClearance(for: bufferedSeg, paddedObstacles: paddedObstacles)
                    let finalSeg = bufferedClearance >= 0 ? bufferedSeg : seg
                    clearCandidates.append(
                        Candidate(
                            segment: finalSeg,
                            bowMagnitude: bufferedMag,
                            clearance: max(clearance, bufferedClearance),
                            boundsMargin: boundsMargin(for: finalSeg, bounds: bounds)
                        )
                    )
                    foundForSign = true
                    break
                }
                mag += 8
            }
        }

        if let chosen = clearCandidates.max(by: { lhs, rhs in
            let lhsInBounds = lhs.boundsMargin >= 0
            let rhsInBounds = rhs.boundsMargin >= 0
            if lhsInBounds != rhsInBounds {
                return !lhsInBounds && rhsInBounds
            }
            let lhsScore = lhs.boundsMargin - lhs.bowMagnitude * 0.30
            let rhsScore = rhs.boundsMargin - rhs.bowMagnitude * 0.30
            return lhsScore < rhsScore
        }) {
            return chosen.segment
        }

        return bestFallback.segment
    }

    public static func handlePoint(
        for segments: [AcousticCurveSegment],
        allNodePoints: [CGPoint],
        obstacles: [CGRect] = []
    ) -> CGPoint? {
        guard !segments.isEmpty else { return nil }
        var bestMidpoint = segments[0].midpoint
        var bestScore = -CGFloat.greatestFiniteMagnitude
        for seg in segments {
            let candidate = seg.midpoint
            let minNodeDist = allNodePoints.map { hypot($0.x - candidate.x, $0.y - candidate.y) }.min() ?? 0
            let minObsDist = obstacles.map { signedDistance(from: candidate, to: $0) }.min() ?? minNodeDist
            let score = min(minNodeDist, minObsDist)
            if score > bestScore {
                bestScore = score
                bestMidpoint = candidate
            }
        }
        return bestMidpoint
    }

    public static func minObstacleClearance(
        for segment: AcousticCurveSegment,
        paddedObstacles: [CGRect],
        midpointExtraPadding: CGFloat = 14
    ) -> CGFloat {
        guard !paddedObstacles.isEmpty else { return .greatestFiniteMagnitude }
        var minClearance = CGFloat.greatestFiniteMagnitude
        let steps = 16
        for i in 0...steps {
            let t = 0.08 + 0.84 * (CGFloat(i) / CGFloat(steps))
            let pt = segment.point(at: t)
            let isMid = abs(t - 0.5) < 0.08
            for obs in paddedObstacles {
                let targetRect = isMid ? obs.insetBy(dx: -midpointExtraPadding, dy: -midpointExtraPadding) : obs
                let dist = signedDistance(from: pt, to: targetRect)
                if dist < minClearance {
                    minClearance = dist
                }
            }
        }
        return minClearance
    }

    private static func boundsMargin(for segment: AcousticCurveSegment, bounds: CGRect?) -> CGFloat {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return 200 }
        let safe = bounds.insetBy(dx: 18, dy: 24)
        var minMargin = CGFloat.greatestFiniteMagnitude
        for t: CGFloat in [0.25, 0.5, 0.75] {
            let p = segment.point(at: t)
            let m = min(
                min(p.x - safe.minX, safe.maxX - p.x),
                min(p.y - safe.minY, safe.maxY - p.y)
            )
            if m < minMargin {
                minMargin = m
            }
        }
        return minMargin
    }

    public static func signedDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if dx > 0 || dy > 0 {
            return hypot(dx, dy)
        }
        let insideX = min(point.x - rect.minX, rect.maxX - point.x)
        let insideY = min(point.y - rect.minY, rect.maxY - point.y)
        return -min(insideX, insideY)
    }
}
