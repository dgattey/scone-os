import SwiftUI
import SconeDomain
import SconeStore

struct FloorplanMapView: View {
    @Environment(SconeStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: SpeakerUUID?
    @State private var dragPoint: CGPoint?
    @State private var dropTarget: SpeakerUUID?
    @State private var selected: SpeakerUUID?
    @State private var hovered: SpeakerUUID?

    private let dropRadius: CGFloat = 65

    var body: some View {
        let nodes = store.state.floorplan
        let groups = store.state.groups
        GeometryReader { geo in
            let plot = CGRect(origin: .zero, size: geo.size).insetBy(dx: 16, dy: 18)
            let anchors = nodes.map { node in
                let name = RoomNaming.shortName(node.speaker.roomName, merged: false)
                return Anchor(
                    id: node.id,
                    name: name,
                    point: displayPoint(node, plot: plot),
                    wing: Wing.match(name),
                    satellites: !node.speaker.model.satellites.isEmpty)
            }
            let plan = HousePlan(anchors: anchors, plot: plot)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = nil
                    }
                Blueprint(plan: plan)
                    .allowsHitTesting(false)
                links(groups: groups, nodes: nodes, plot: plot)
                    .allowsHitTesting(false)
                ForEach(nodes) { node in
                    nodeView(node, groups: groups, plot: plot)
                }
            }
            .coordinateSpace(.named("house"))
        }
        .padding(12)
        .midnightGlass(radius: 28)
        .padding(16)
    }

    private func nodeView(_ node: FloorplanNode, groups: [SonosGroup], plot: CGRect) -> some View {
        let name = RoomNaming.shortName(node.speaker.roomName, merged: false)
        let group = node.group.flatMap { id in groups.first { $0.id == id } }
        let playing = group.map { playbackIsActive($0.playback) } ?? false
        let grouped = (group?.speakers.count ?? 0) > 1
        let point = displayPoint(node, plot: plot)
        let showsVolume = (hovered == node.id || selected == node.id) && dragging != node.id
        return RoomNode(
            node: node,
            name: name,
            playing: playing,
            grouped: grouped,
            dropTarget: dropTarget == node.id,
            showsVolume: showsVolume,
            onVolume: { volume in
                store.send(.setVolume(volume, for: .speaker(node.speaker.id)))
            })
            .position(point)
            .zIndex(dragging == node.id ? 3 : (showsVolume || dropTarget == node.id ? 2 : 0))
            .gesture(drag(node, plot: plot))
            .onTapGesture { selected = node.id }
            .onHover { inside in
                if inside {
                    hovered = node.id
                } else if hovered == node.id {
                    hovered = nil
                }
            }
    }

    private func drag(_ node: FloorplanNode, plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("house"))
            .onChanged { value in
                dragging = node.id
                dragPoint = value.location
                let next = nearest(to: value.location, excluding: node.id, plot: plot)
                if next != dropTarget, next != nil {
                    acousticTick()
                }
                dropTarget = next
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved >= 6 {
                    if let target = nearest(to: value.location, excluding: node.id, plot: plot) {
                        store.group(member: node.id, onto: target)
                    } else {
                        store.moveRoom(node.id, to: coordinate(at: value.location, plot: plot))
                    }
                }
                dragging = nil
                dragPoint = nil
                dropTarget = nil
            }
    }

    @ViewBuilder
    private func links(groups: [SonosGroup], nodes: [FloorplanNode], plot: CGRect) -> some View {
        if reduceMotion {
            linkLayer(groups: groups, nodes: nodes, plot: plot, phase: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.6) / 2.6
                linkLayer(groups: groups, nodes: nodes, plot: plot, phase: phase)
            }
        }
    }

    private func linkLayer(groups: [SonosGroup], nodes: [FloorplanNode], plot: CGRect, phase: Double?) -> some View {
        let linked = groups.filter { $0.speakers.count > 1 }
        return ZStack {
            ForEach(linked) { group in
                let points = ordered(group.speakers.compactMap { speaker in
                    nodes.first { $0.id == speaker.id }.map { displayPoint($0, plot: plot) }
                })
                AcousticLink(points: points, phase: phase)
            }
        }
    }

    private func displayPoint(_ node: FloorplanNode, plot: CGRect) -> CGPoint {
        if node.id == dragging, let dragPoint { return dragPoint }
        return CGPoint(
            x: plot.minX + node.coordinate.x * plot.width,
            y: plot.minY + node.coordinate.y * plot.height)
    }

    private func coordinate(at point: CGPoint, plot: CGRect) -> RoomCoordinate {
        let x = plot.width > 0 ? (point.x - plot.minX) / plot.width : 0.5
        let y = plot.height > 0 ? (point.y - plot.minY) / plot.height : 0.5
        return RoomCoordinate(clampingX: x, y: y)
    }

    private func nearest(to point: CGPoint, excluding id: SpeakerUUID, plot: CGRect) -> SpeakerUUID? {
        var best: SpeakerUUID?
        var bestDistance = dropRadius
        for node in store.state.floorplan where node.id != id {
            let center = displayPoint(node, plot: plot)
            let distance = hypot(center.x - point.x, center.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = node.id
            }
        }
        return best
    }
}

private struct RoomNode: View {
    var node: FloorplanNode
    var name: String
    var playing: Bool
    var grouped: Bool
    var dropTarget: Bool
    var showsVolume: Bool
    var onVolume: (DiscreteVolume) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if dropTarget {
                    Circle()
                        .stroke(MidnightGlass.gold, lineWidth: 2)
                        .background(Circle().fill(MidnightGlass.copper.opacity(0.16)))
                        .frame(width: 84, height: 84)
                        .shadow(color: MidnightGlass.copper.opacity(0.9), radius: 12)
                }
                SpeakerSilhouetteView(
                    model: node.speaker.model,
                    isOnline: node.speaker.reachability.isOnline,
                    isPlaying: playing,
                    isGrouped: grouped,
                    size: 64)
            }
            .frame(height: 72)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 108)
            HStack(spacing: 4) {
                if !node.speaker.reachability.isOnline {
                    OfflinePill()
                }
                if playing {
                    PlayingMark()
                }
            }
            .frame(height: 16)
        }
        .frame(width: 120)
        .overlay(alignment: .bottom) {
            if showsVolume {
                DiscreteVolumeControl(volume: node.speaker.volume, compact: true, onChange: onVolume)
                    .frame(width: 176)
                    .offset(y: 42)
            }
        }
    }
}

private struct AcousticLink: View {
    var points: [CGPoint]
    var phase: Double?

    var body: some View {
        let path = acousticPath(through: points)
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { item in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [MidnightGlass.gold.opacity(0.45), MidnightGlass.copper.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 28))
                    .frame(width: 56, height: 56)
                    .position(item.element)
            }
            path
                .stroke(MidnightGlass.copper.opacity(0.28), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .blur(radius: 6)
            path
                .stroke(
                    LinearGradient(
                        colors: [MidnightGlass.copper, MidnightGlass.gold],
                        startPoint: .leading,
                        endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if let phase {
                path
                    .trim(from: phase > 0.2 ? phase - 0.2 : 0, to: min(phase, 1))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
    }
}

private func ordered(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }
    let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
    let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
    return points.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
}

private func acousticPath(through points: [CGPoint]) -> Path {
    var path = Path()
    guard points.count >= 2 else { return path }
    if points.count == 2 {
        let start = points[0]
        let end = points[1]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)
        let bow = min(64, length * 0.3)
        let control = CGPoint(
            x: (start.x + end.x) / 2 + (-dy / length) * bow,
            y: (start.y + end.y) / 2 + (dx / length) * bow)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
    path.move(to: points[0])
    let count = points.count
    for index in 0..<count {
        let p0 = points[(index - 1 + count) % count]
        let p1 = points[index]
        let p2 = points[(index + 1) % count]
        let p3 = points[(index + 2) % count]
        let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: control1, control2: control2)
    }
    path.closeSubpath()
    return path
}

private struct Anchor {
    var id: SpeakerUUID
    var name: String
    var point: CGPoint
    var wing: Wing?
    var satellites: Bool
}

private enum Wing: String {
    case kitchen, dining, living, bedroom, guest, basement

    var title: String {
        switch self {
        case .kitchen: "Kitchen"
        case .dining: "Dining Room"
        case .living: "Living Room"
        case .bedroom: "Bedroom"
        case .guest: "Guest Room"
        case .basement: "Basement"
        }
    }

    static func match(_ name: String) -> Wing? {
        let value = name.lowercased()
        if value.contains("kitchen") { return .kitchen }
        if value.contains("dining") { return .dining }
        if value.contains("living") { return .living }
        if value.contains("guest") { return .guest }
        if value.contains("bed") { return .bedroom }
        if value.contains("base") { return .basement }
        return nil
    }
}

private enum Story: CaseIterable {
    case main, upper, lower

    var title: String {
        switch self {
        case .main: "Main Level"
        case .upper: "Upper Suite"
        case .lower: "Lower Level"
        }
    }

    var wings: [Wing] {
        switch self {
        case .main: [.kitchen, .dining, .living]
        case .upper: [.bedroom, .guest]
        case .lower: [.basement]
        }
    }
}

private struct NormBox {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    func rect(in plot: CGRect) -> CGRect {
        CGRect(
            x: plot.minX + x * plot.width,
            y: plot.minY + y * plot.height,
            width: w * plot.width,
            height: h * plot.height)
    }
}

private let wingFallback: [Wing: NormBox] = [
    .kitchen: NormBox(x: 0.08, y: 0.08, w: 0.28, h: 0.34),
    .dining: NormBox(x: 0.38, y: 0.08, w: 0.28, h: 0.34),
    .living: NormBox(x: 0.68, y: 0.08, w: 0.26, h: 0.36),
    .bedroom: NormBox(x: 0.08, y: 0.52, w: 0.28, h: 0.36),
    .guest: NormBox(x: 0.38, y: 0.52, w: 0.28, h: 0.36),
    .basement: NormBox(x: 0.68, y: 0.52, w: 0.26, h: 0.38),
]

private struct HousePlan {
    struct Room: Identifiable {
        var id: String
        var title: String
        var frame: CGRect
        var dots: [CGPoint]
    }

    struct Level: Identifiable {
        var id: String
        var title: String
        var frame: CGRect
        var rooms: [Room]
    }

    var levels: [Level]

    init(anchors: [Anchor], plot: CGRect) {
        levels = Story.allCases.compactMap { story in
            let rooms = story.wings.map { wing in
                let fallback = wingFallback[wing]?.rect(in: plot) ?? plot
                let points = anchors.filter { $0.wing == wing }.map(\.point)
                var dots: [CGPoint] = []
                if wing == .living {
                    for anchor in anchors where anchor.wing == .living && anchor.satellites {
                        dots.append(CGPoint(x: anchor.point.x - 34, y: anchor.point.y + 18))
                        dots.append(CGPoint(x: anchor.point.x + 34, y: anchor.point.y + 18))
                    }
                }
                return Room(id: wing.rawValue, title: wing.title, frame: grown(fallback, around: points), dots: dots)
            }
            guard var frame = rooms.first?.frame else { return nil }
            for room in rooms.dropFirst() {
                frame = frame.union(room.frame)
            }
            frame = frame.insetBy(dx: -8, dy: -8)
            return Level(id: story.title, title: story.title, frame: frame, rooms: rooms)
        }
    }
}

private func grown(_ fallback: CGRect, around points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return fallback }
    if points.allSatisfy({ fallback.insetBy(dx: 12, dy: 12).contains($0) }) {
        return fallback
    }
    var rect = CGRect(origin: first, size: .zero)
    for point in points.dropFirst() {
        rect = rect.union(CGRect(origin: point, size: .zero))
    }
    return rect.insetBy(dx: -54, dy: -46).union(fallback)
}

private struct Blueprint: View {
    var plan: HousePlan

    var body: some View {
        ZStack {
            Canvas { context, _ in
                guard var outer = plan.levels.first?.frame else { return }
                for level in plan.levels.dropFirst() {
                    outer = outer.union(level.frame)
                }
                outer = outer.insetBy(dx: -14, dy: -14)
                let wall = Path(roundedRect: outer, cornerRadius: 18)
                context.stroke(wall, with: .color(Color.white.opacity(0.16)), lineWidth: 1)
                for level in plan.levels {
                    let levelPath = Path(roundedRect: level.frame, cornerRadius: 14)
                    context.fill(levelPath, with: .color(Color.white.opacity(0.035)))
                    context.stroke(levelPath, with: .color(MidnightGlass.copper.opacity(0.28)), lineWidth: 1)
                    for room in level.rooms {
                        let roomPath = Path(roundedRect: room.frame, cornerRadius: 10)
                        context.stroke(roomPath, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
                        for dot in room.dots {
                            let mark = CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)
                            context.fill(Path(ellipseIn: mark), with: .color(MidnightGlass.gold.opacity(0.85)))
                        }
                    }
                }
            }
            ForEach(plan.levels) { level in
                Text(level.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(MidnightGlass.gold.opacity(0.55))
                    .position(x: level.frame.midX, y: max(14, level.frame.minY - 12))
            }
        }
        .allowsHitTesting(false)
    }
}
