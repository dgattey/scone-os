import SwiftUI
import SconeDomain
import SconeStore

private struct SpeakerTether: Equatable {
    let speakerID: SpeakerUUID
    let roomName: String
    let segment: AcousticCurveSegment
    let severPoint: CGPoint
}

private struct MapGeometryKey: Equatable {
    struct NodeKey: Equatable {
        let id: SpeakerUUID
        let x: Int
        let y: Int
        let level: FloorLevel
        let group: GroupID?
        let hasSatellites: Bool
    }
    struct HubKey: Equatable {
        let id: GroupID
        let memberIDs: [SpeakerUUID]
    }
    let width: Int
    let height: Int
    let nodes: [NodeKey]
    let hubs: [HubKey]
}

private struct PrecomputedMapGeometry {
    let bands: [FloorBandLayout]
    let hubLocations: [GroupID: CGPoint]
    let displayPoints: [SpeakerUUID: CGPoint]
    let tethersByGroup: [GroupID: [SpeakerTether]]
    let canvasSize: CGSize
}

private final class MapGeometryMemoizer {
    private var lastKey: MapGeometryKey?
    private var lastGeometry: PrecomputedMapGeometry?

    func resolve(key: MapGeometryKey, compute: () -> PrecomputedMapGeometry) -> PrecomputedMapGeometry {
        if lastKey == key, let lastGeometry {
            return lastGeometry
        }
        let next = compute()
        lastKey = key
        lastGeometry = next
        return next
    }
}

struct FloorplanMapView: View {
    @Environment(SconeStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSelectGroup: ((GroupID) -> Void)? = nil

    @State private var dragging: SpeakerUUID?
    @State private var dragPoint: CGPoint?
    @State private var dropTarget: MapDropTarget?
    @State private var selected: SpeakerUUID?
    @State private var hovered: SpeakerUUID?
    @State private var hoveredTetherSpeaker: SpeakerUUID?
    @State private var geometryMemoizer = MapGeometryMemoizer()

    private let dropRadius: CGFloat = FloorplanDragHitTesting.defaultDropRadius

    var body: some View {
        let nodes = store.state.floorplan
        let groups = store.state.groups
        let topologyKey = groups.map { "\($0.id.coordinator.rawValue):\($0.speakers.map(\.id.rawValue).joined(separator: ","))" }.joined(separator: "|")

        GeometryReader { geo in
            let isCompact = geo.size.width < 520 || LaunchView.requestsIOS()
            if isCompact {
                CompactFloorplanMapView(
                    nodes: nodes,
                    groups: groups,
                    selected: $selected,
                    onSelectGroup: onSelectGroup
                )
            } else {
                let hubGroups = activeHubGroups(from: groups)
                let geometry = memoizedGeometry(
                    nodes: nodes,
                    hubGroups: hubGroups,
                    viewportSize: geo.size
                )
                let plot = CGRect(origin: .zero, size: geometry.canvasSize).insetBy(dx: 24, dy: 16)
                let bands = geometry.bands
                let hubLocations = geometry.hubLocations

                ScrollView(.vertical, showsIndicators: geometry.canvasSize.height > geo.size.height + 4) {
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.2)) {
                                    selected = nil
                                }
                            }

                        FloorBandsBackdrop(bands: bands)
                            .allowsHitTesting(false)

                        links(
                            hubGroups: hubGroups,
                            tethersByGroup: geometry.tethersByGroup
                        )
                        .allowsHitTesting(false)

                        if let currentPoint = dragPoint,
                           let target = dropTarget,
                           let targetPoint = targetPosition(
                               target,
                               geometry: geometry
                           ) {
                            DragPreviewTether(from: currentPoint, to: targetPoint)
                                .allowsHitTesting(false)
                                .zIndex(1)
                        }

                        ForEach(nodes) { node in
                            nodeView(
                                node,
                                groups: groups,
                                nodes: nodes,
                                geometry: geometry,
                                plot: plot
                            )
                        }

                        ForEach(hubGroups) { group in
                            if let hubPoint = hubLocations[group.id] {
                                musicHubView(group: group, position: hubPoint)
                                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                    .zIndex(3.2)
                            }
                        }

                        tetherSeverButtons(
                            hubGroups: hubGroups,
                            tethersByGroup: geometry.tethersByGroup
                        )
                        .zIndex(3.8)

                        if let selectedID = selected,
                           dragging == nil,
                           let selectedNode = nodes.first(where: { $0.id == selectedID }) {
                            selectedNodeOverlay(
                                selectedNode,
                                groups: groups,
                                geometry: geometry,
                                plot: plot
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .zIndex(5)
                        }
                    }
                    .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
                    .coordinateSpace(.named("house"))
                    .animation(.spring(response: 0.38, dampingFraction: 0.84), value: topologyKey)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func activeHubGroups(from groups: [SonosGroup]) -> [SonosGroup] {
        deduplicatedActiveHubGroups(from: groups)
    }

    private func memoizedGeometry(
        nodes: [FloorplanNode],
        hubGroups: [SonosGroup],
        viewportSize: CGSize
    ) -> PrecomputedMapGeometry {
        let key = MapGeometryKey(
            width: Int(viewportSize.width.rounded()),
            height: Int(viewportSize.height.rounded()),
            nodes: nodes.map {
                MapGeometryKey.NodeKey(
                    id: $0.id,
                    x: Int(($0.coordinate.x * 1000).rounded()),
                    y: Int(($0.coordinate.y * 1000).rounded()),
                    level: $0.level,
                    group: $0.group,
                    hasSatellites: !$0.speaker.bondedSatellites.isEmpty
                )
            },
            hubs: hubGroups.map {
                MapGeometryKey.HubKey(id: $0.id, memberIDs: $0.speakers.map(\.id))
            }
        )

        return geometryMemoizer.resolve(key: key) {
            var activeHubCountByLevel: [FloorLevel: Int] = [:]
            for group in hubGroups {
                let memberNodes = group.speakers.compactMap { spk in nodes.first { $0.id == spk.id } }
                if let primaryLevel = memberNodes.first?.level {
                    activeHubCountByLevel[primaryLevel, default: 0] += 1
                }
            }

            let initialPlot = CGRect(origin: .zero, size: viewportSize).insetBy(dx: 24, dy: 16)
            let bands = FloorBandLayout.compute(
                nodes: nodes,
                in: initialPlot,
                activeHubCountByLevel: activeHubCountByLevel
            )
            let maxBandBottom = bands.map(\.frame.maxY).max() ?? initialPlot.maxY
            let requiredHeight = max(viewportSize.height, maxBandBottom + 16)
            let canvasSize = CGSize(width: viewportSize.width, height: requiredHeight)
            let plot = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 24, dy: 16)

            var hubLocations = computeHubLocations(
                hubGroups: hubGroups,
                nodes: nodes,
                bands: bands,
                plot: plot
            )
            var displayPoints: [SpeakerUUID: CGPoint] = [:]
            for node in nodes {
                displayPoints[node.id] = computeDisplayPoint(
                    node,
                    bands: bands,
                    hubLocations: hubLocations,
                    plot: plot
                )
            }
            for band in bands {
                let bandNodes = nodes.filter { $0.level == band.level }
                let roomSpecs = bandNodes.map { node in
                    AcousticCurveRouter.LayoutRoomSpec(
                        id: node.id,
                        center: displayPoints[node.id] ?? baseDisplayPoint(node, bands: bands, plot: plot),
                        hasSatellites: !node.speaker.bondedSatellites.isEmpty,
                        isFixed: false
                    )
                }
                let bandHubs = hubLocations.filter { _, pt in band.frame.contains(pt) }
                let resolved = AcousticCurveRouter.resolveBandCollisions(
                    rooms: roomSpecs,
                    hubCenters: bandHubs,
                    bandFrame: band.frame
                )
                for (id, pt) in resolved.roomCenters {
                    displayPoints[id] = pt
                }
                for (gID, pt) in resolved.hubCenters {
                    hubLocations[gID] = pt
                }
            }
            let allObstacles = nodes.map { node in
                AcousticCurveRouter.nodeObstacleRect(
                    center: displayPoints[node.id] ?? .zero,
                    hasSatellites: !node.speaker.bondedSatellites.isEmpty
                )
            }
            var tethersByGroup: [GroupID: [SpeakerTether]] = [:]
            for group in hubGroups {
                guard let hubPoint = hubLocations[group.id] else { continue }
                let hubRect = AcousticCurveRouter.musicHubRect(center: hubPoint)
                tethersByGroup[group.id] = group.speakers.compactMap { speaker -> SpeakerTether? in
                    guard let node = nodes.first(where: { $0.id == speaker.id }),
                          let speakerPoint = displayPoints[node.id] else { return nil }
                    let speakerRect = AcousticCurveRouter.nodeObstacleRect(
                        center: speakerPoint,
                        hasSatellites: !node.speaker.bondedSatellites.isEmpty
                    )
                    let seg = AcousticCurveRouter.routeTether(
                        startRect: hubRect,
                        endRect: speakerRect,
                        obstacles: allObstacles,
                        bounds: plot,
                        inset: 2
                    )
                    let roomName = RoomNaming.shortName(speaker.roomName, merged: false)
                    return SpeakerTether(
                        speakerID: speaker.id,
                        roomName: roomName,
                        segment: seg,
                        severPoint: seg.point(at: 0.5)
                    )
                }
            }
            return PrecomputedMapGeometry(
                bands: bands,
                hubLocations: hubLocations,
                displayPoints: displayPoints,
                tethersByGroup: tethersByGroup,
                canvasSize: canvasSize
            )
        }
    }

    private func computeHubLocations(
        hubGroups: [SonosGroup],
        nodes: [FloorplanNode],
        bands: [FloorBandLayout],
        plot: CGRect
    ) -> [GroupID: CGPoint] {
        var result: [GroupID: CGPoint] = [:]
        var placedHubRects: [CGRect] = []
        let basePoints = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, baseDisplayPoint($0, bands: bands, plot: plot)) })
        let roomObstacles = nodes.compactMap { node -> CGRect? in
            guard let pt = basePoints[node.id] else { return nil }
            return AcousticCurveRouter.nodeObstacleRect(
                center: pt,
                hasSatellites: !node.speaker.bondedSatellites.isEmpty
            )
        }

        for group in hubGroups {
            let memberNodes = group.speakers.compactMap { spk in nodes.first { $0.id == spk.id } }
            let connectedPoints = memberNodes.compactMap { basePoints[$0.id] }
            guard !connectedPoints.isEmpty else { continue }

            let targetLevel = memberNodes.first?.level
            let bounds: CGRect = if let level = targetLevel,
                                    let band = bands.first(where: { $0.level == level }) {
                CGRect(
                    x: band.frame.minX + 16,
                    y: band.frame.minY + FloorBandLayout.headerHeight + 8,
                    width: max(80, band.frame.width - 32),
                    height: max(60, band.frame.height - FloorBandLayout.headerHeight - 16)
                )
            } else {
                plot
            }

            let center = AcousticCurveRouter.placeMusicHub(
                connectedPoints: connectedPoints,
                roomObstacles: roomObstacles,
                existingHubs: placedHubRects,
                bounds: bounds
            )
            result[group.id] = center
            placedHubRects.append(AcousticCurveRouter.musicHubRect(center: center))
        }
        return result
    }

    private func musicHubView(group: SonosGroup, position: CGPoint) -> some View {
        let isPlaying = playbackIsActive(group.playback)
        let isDropTarget = (dropTarget == .musicHub(group.id))
        return MusicSourceNodeView(
            group: group,
            externalSpotify: store.state.externalSpotify,
            isPlaying: isPlaying,
            isDropTarget: isDropTarget,
            onTogglePlay: {
                acousticTick()
                store.togglePlayOrHandOffSpotify(for: group)
            },
            onOpenDetail: {
                onSelectGroup?(group.id)
            }
        )
        .contextMenu {
            SpeakerGroupContextMenu(group: group, onOpenGroup: onSelectGroup)
        }
        .position(position)
    }

    private func nodeView(
        _ node: FloorplanNode,
        groups: [SonosGroup],
        nodes: [FloorplanNode],
        geometry: PrecomputedMapGeometry,
        plot: CGRect
    ) -> some View {
        let name = RoomNaming.shortName(node.speaker.roomName, merged: false)
        let group = node.group.flatMap { id in groups.first { $0.id == id } }
        let playing = group.map { playbackIsActive($0.playback) } ?? false
        let connectedToHub = group.map { geometry.hubLocations[$0.id] != nil } ?? false
        let settledPoint = geometry.displayPoints[node.id] ?? baseDisplayPoint(node, bands: geometry.bands, plot: plot)
        let isHovered = hovered == node.id
        let isSelected = selected == node.id
        let isDropTarget = (dropTarget == .speaker(node.id))
        let isBeingDragged = dragging == node.id
        let activePoint = (isBeingDragged ? dragPoint : nil) ?? settledPoint

        return RoomContainerNode(
            node: node,
            name: name,
            playing: playing,
            connectedToHub: connectedToHub,
            isHovered: isHovered,
            isSelected: isSelected,
            dropTarget: isDropTarget
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if selected == node.id {
                if let group = node.group {
                    onSelectGroup?(group)
                }
            } else {
                withAnimation(.snappy(duration: 0.2)) {
                    selected = node.id
                }
            }
        }
        .gesture(drag(node, geometry: geometry, plot: plot))
        .onHover { inside in
            withAnimation(.snappy(duration: 0.16)) {
                if inside {
                    hovered = node.id
                } else if hovered == node.id {
                    hovered = nil
                }
            }
        }
        .contextMenu {
            SpeakerGroupContextMenu(
                group: group,
                speaker: node.speaker,
                isPinnedOnMap: node.placement == .pinned,
                onOpenGroup: onSelectGroup
            )
        }
        .position(activePoint)
        .zIndex(isBeingDragged ? 4 : (isDropTarget || isSelected ? 3 : 2))
    }

    private func selectedNodeOverlay(
        _ node: FloorplanNode,
        groups: [SonosGroup],
        geometry: PrecomputedMapGeometry,
        plot: CGRect
    ) -> some View {
        let point = geometry.displayPoints[node.id] ?? baseDisplayPoint(node, bands: geometry.bands, plot: plot)
        let hasSats = !node.speaker.bondedSatellites.isEmpty
        let extraOffset: CGFloat = hasSats ? 84 : 66
        let placeAbove = point.y > plot.maxY - 96
        let popoverY = placeAbove ? max(plot.minY + 26, point.y - 66) : min(plot.maxY - 16, point.y + extraOffset)
        let clampedX = min(max(point.x, plot.minX + 128), plot.maxX - 128)
        let group = node.group.flatMap { id in groups.first { $0.id == id } }

        return HStack(spacing: 8) {
            if let group {
                Button {
                    store.togglePlayOrHandOffSpotify(for: group)
                } label: {
                    Image(systemName: playbackIsActive(group.playback) ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(MidnightGlass.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(MidnightGlass.gold))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(playbackIsActive(group.playback) ? "Pause" : "Play")
            }
            DiscreteVolumeControl(volume: node.speaker.volume, compact: true) { volume in
                store.send(.setVolume(volume, for: .speaker(node.speaker.id)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 252)
        .midnightGlass(glowing: true, radius: 16)
        .position(x: clampedX, y: popoverY)
    }

    private func drag(
        _ node: FloorplanNode,
        geometry: PrecomputedMapGeometry,
        plot: CGRect
    ) -> some Gesture {
        let hasSats = !node.speaker.bondedSatellites.isEmpty
        return DragGesture(minimumDistance: 4, coordinateSpace: .named("house"))
            .onChanged { value in
                if selected != nil { selected = nil }
                dragging = node.id
                let next = nearestTarget(
                    to: value.location,
                    excluding: node.id,
                    geometry: geometry
                )
                if next != nil {
                    dragPoint = value.location
                } else if let band = geometry.bands.first(where: { $0.level == node.level }) {
                    dragPoint = band.clampPoint(value.location, hasSatellites: hasSats)
                } else {
                    dragPoint = value.location
                }
                if next != dropTarget, next != nil {
                    acousticTick()
                }
                dropTarget = next
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved >= 4 {
                    if let target = nearestTarget(
                        to: value.location,
                        excluding: node.id,
                        geometry: geometry
                    ) {
                        acousticTick()
                        switch target {
                        case .speaker(let targetSpeakerID):
                            store.group(member: node.id, onto: targetSpeakerID)
                        case .musicHub(let groupID):
                            if let group = store.state.groups.first(where: { $0.id == groupID }),
                               group.coordinator.id != node.id {
                                store.group(member: node.id, onto: group.coordinator.id)
                            }
                        }
                    } else if let band = geometry.bands.first(where: { $0.level == node.level }) {
                        store.moveRoom(node.id, to: band.coordinate(for: value.location, hasSatellites: hasSats))
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
    private func links(
        hubGroups: [SonosGroup],
        tethersByGroup: [GroupID: [SpeakerTether]]
    ) -> some View {
        let anyPlaying = hubGroups.contains(where: { playbackIsActive($0.playback) })
        if reduceMotion || !anyPlaying {
            linkLayer(
                hubGroups: hubGroups,
                tethersByGroup: tethersByGroup,
                phase: nil
            )
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.6) / 2.6
                linkLayer(
                    hubGroups: hubGroups,
                    tethersByGroup: tethersByGroup,
                    phase: phase
                )
            }
        }
    }

    private func linkLayer(
        hubGroups: [SonosGroup],
        tethersByGroup: [GroupID: [SpeakerTether]],
        phase: Double?
    ) -> some View {
        ZStack {
            ForEach(hubGroups) { group in
                if let tethers = tethersByGroup[group.id], !tethers.isEmpty {
                    let endpoints = tethers.flatMap { [$0.segment.start, $0.segment.end] }
                    AcousticLink(
                        points: endpoints,
                        segments: tethers.map(\.segment),
                        phase: playbackIsActive(group.playback) ? phase : nil
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    private func tetherSeverButtons(
        hubGroups: [SonosGroup],
        tethersByGroup: [GroupID: [SpeakerTether]]
    ) -> some View {
        ZStack {
            ForEach(hubGroups) { group in
                if group.speakers.count > 1, let tethers = tethersByGroup[group.id] {
                    ForEach(tethers, id: \.speakerID) { tether in
                        TetherSeverOverlay(
                            tether: tether,
                            isRoomHovered: hovered == tether.speakerID,
                            onSever: {
                                acousticTick()
                                store.ungroupSpeaker(tether.speakerID)
                            }
                        )
                    }
                }
            }
        }
    }

    private func baseDisplayPoint(
        _ node: FloorplanNode,
        bands: [FloorBandLayout],
        plot: CGRect
    ) -> CGPoint {
        let hasSats = !node.speaker.bondedSatellites.isEmpty
        if let band = bands.first(where: { $0.level == node.level }) {
            return band.point(for: node.coordinate, hasSatellites: hasSats)
        }
        return CGPoint(
            x: plot.minX + node.coordinate.x * plot.width,
            y: plot.minY + node.coordinate.y * plot.height
        )
    }

    private func computeDisplayPoint(
        _ node: FloorplanNode,
        bands: [FloorBandLayout],
        hubLocations: [GroupID: CGPoint],
        plot: CGRect
    ) -> CGPoint {
        let base = baseDisplayPoint(node, bands: bands, plot: plot)
        guard let band = bands.first(where: { $0.level == node.level }),
              !hubLocations.isEmpty else {
            return base
        }
        let nearestHub = hubLocations.values.min { lhs, rhs in
            hypot(lhs.x - base.x, lhs.y - base.y) < hypot(rhs.x - base.x, rhs.y - base.y)
        }
        return AcousticCurveRouter.nudgedRoomPoint(
            basePoint: base,
            hubCenter: nearestHub,
            safeRect: band.safeInnerRect
        )
    }

    private func coordinate(at point: CGPoint, plot: CGRect) -> RoomCoordinate {
        let x = plot.width > 0 ? (point.x - plot.minX) / plot.width : 0.5
        let y = plot.height > 0 ? (point.y - plot.minY) / plot.height : 0.5
        return RoomCoordinate(clampingX: x, y: y)
    }

    private func targetPosition(
        _ target: MapDropTarget,
        geometry: PrecomputedMapGeometry
    ) -> CGPoint? {
        switch target {
        case .speaker(let id):
            return geometry.displayPoints[id]
        case .musicHub(let groupID):
            return geometry.hubLocations[groupID]
        }
    }

    private func nearestTarget(
        to point: CGPoint,
        excluding id: SpeakerUUID,
        geometry: PrecomputedMapGeometry
    ) -> MapDropTarget? {
        let draggedGroup = store.state.floorplan.first(where: { $0.id == id })?.group
        return FloorplanDragHitTesting.nearestTarget(
            to: point,
            excluding: id,
            draggedGroup: draggedGroup,
            displayPoints: geometry.displayPoints,
            hubLocations: geometry.hubLocations,
            dropRadius: dropRadius
        )
    }
}

/// Simple, shadowless inner room container on the floorplan.
private struct RoomContainerNode: View {
    var node: FloorplanNode
    var name: String
    var playing: Bool
    var connectedToHub: Bool
    var isHovered: Bool
    var isSelected: Bool
    var dropTarget: Bool
    var flexibleWidth: Bool = false

    private var satellites: [BondedSatellite] {
        node.speaker.bondedSatellites
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(connectedToHub || isSelected ? MidnightGlass.gold : MidnightGlass.primaryText.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            SpeakerSilhouetteView(
                model: node.speaker.model,
                isOnline: node.speaker.reachability.isOnline,
                isPlaying: playing,
                isGrouped: connectedToHub,
                size: 46
            )

            if dropTarget {
                Text("Connect")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MidnightGlass.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(MidnightGlass.gold))
            } else if let battery = node.speaker.model.battery {
                SpeakerBatteryBadge(battery: battery)
            } else if !node.speaker.reachability.isOnline {
                OfflinePill()
            } else {
                Text("\(node.speaker.volume.percent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MidnightGlass.secondaryText)
            }

            if !satellites.isEmpty {
                BondedSatellitesMapStrip(satellites: satellites, isPlaying: playing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: flexibleWidth ? nil : (satellites.isEmpty ? 138 : 196))
        .frame(maxWidth: flexibleWidth ? .infinity : nil)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MidnightGlass.roomEnclosureFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    dropTarget
                        ? MidnightGlass.gold
                        : (connectedToHub || isSelected
                            ? MidnightGlass.gold.opacity(0.68)
                            : (isHovered ? MidnightGlass.gold.opacity(0.45) : MidnightGlass.roomEnclosureBorder)),
                    lineWidth: dropTarget ? 2 : (connectedToHub || isSelected ? 1.25 : 1)
                )
        }
        .scaleEffect(dropTarget ? 1.04 : (isHovered ? 1.015 : 1.0))
        .animation(.spring(duration: 0.18), value: dropTarget)
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

/// Coherent Music Square node on the map connected to each speaker playing its music.
private struct MusicSourceNodeView: View {
    static let cardSize = CGSize(width: 368, height: 108)

    var group: SonosGroup
    var externalSpotify: SpotifyTrackContext? = nil
    var isPlaying: Bool
    var isDropTarget: Bool
    var flexibleWidth: Bool = false
    var onTogglePlay: () -> Void
    var onOpenDetail: () -> Void

    @State private var isHovered = false

    private var track: NowPlayingTrack? {
        if case .track(let t) = group.playback.nowPlaying {
            return t
        }
        return nil
    }

    private var activeExternalSpotify: SpotifyTrackContext? {
        guard group.playback.nowPlaying == nil else { return nil }
        return externalSpotify
    }

    private var resolvedArtworkURL: URL? {
        track?.artworkURL ?? activeExternalSpotify?.metadata.artworkURL
    }

    private var titleText: String {
        if let track, !track.title.isEmpty {
            return track.title
        }
        if let externalTitle = activeExternalSpotify?.metadata.title, !externalTitle.isEmpty {
            return externalTitle
        }
        switch group.playback.nowPlaying {
        case .tvAudio:
            return "TV Audio"
        case .stream(let title):
            return title ?? ""
        default:
            return group.displayName
        }
    }

    private var subtitleText: String {
        if let track, let artist = track.artist, !artist.isEmpty {
            return artist
        }
        let roomCountText = "\(group.speakers.count) \(group.speakers.count == 1 ? "room" : "rooms")"
        if let externalArtist = activeExternalSpotify?.metadata.artist, !externalArtist.isEmpty {
            return "\(externalArtist) · \(roomCountText)"
        }
        return roomCountText
    }

    private var externalDeviceCaption: String? {
        activeExternalSpotify?.externalPlaybackLabel
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenDetail) {
                HStack(spacing: 11) {
                    AlbumArtworkView(
                        url: resolvedArtworkURL,
                        size: flexibleWidth ? 64 : (activeExternalSpotify != nil ? 68 : 76),
                        cornerRadius: 13
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(titleText)
                            .font(.system(size: flexibleWidth ? 15 : 15, weight: .bold))
                            .foregroundStyle(MidnightGlass.primaryText)
                            .lineLimit(activeExternalSpotify == nil ? 2 : 1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(subtitleText)
                            .font(.system(size: flexibleWidth ? 12 : 12.5, weight: .medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)

                        if let externalDeviceCaption {
                            HStack(spacing: 4) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                Text(externalDeviceCaption)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .foregroundStyle(MidnightGlass.gold)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Button(action: onTogglePlay) {
                if activeExternalSpotify != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("Play here")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .fixedSize()
                    .foregroundStyle(MidnightGlass.ink)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Capsule().fill(MidnightGlass.gold))
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(isPlaying ? MidnightGlass.ink : MidnightGlass.gold)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(isPlaying ? MidnightGlass.gold : MidnightGlass.subtleFill)
                        )
                        .overlay(
                            Circle().strokeBorder(MidnightGlass.gold.opacity(0.75), lineWidth: 1.2)
                        )
                }
            }
            .buttonStyle(PressableStyle())
            .focusEffectDisabled()
            .help(
                activeExternalSpotify != nil
                    ? "Play on \(group.displayName)"
                    : (isPlaying ? "Pause \(group.displayName)" : "Play \(group.displayName)")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: flexibleWidth ? nil : Self.cardSize.width, height: flexibleWidth ? nil : Self.cardSize.height)
        .frame(maxWidth: flexibleWidth ? .infinity : nil)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MidnightGlass.cardElevatedFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isDropTarget ? MidnightGlass.gold : MidnightGlass.gold.opacity(isHovered ? 0.96 : 0.84),
                    lineWidth: isDropTarget ? 2.2 : 1.5
                )
        }
        .scaleEffect(isDropTarget ? 1.05 : (isHovered ? 1.015 : 1.0))
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .animation(.spring(duration: 0.18), value: isDropTarget)
    }
}

private struct TetherSeverOverlay: View {
    var tether: SpeakerTether
    var isRoomHovered: Bool
    var onSever: () -> Void

    @State private var isZoneHovered = false
    @State private var isPillHovered = false

    private var isVisible: Bool {
        isZoneHovered || isPillHovered || isRoomHovered
    }

    var body: some View {
        Button(action: onSever) {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 44, height: 44)

                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isPillHovered ? MidnightGlass.ink : MidnightGlass.gold)
                    .frame(width: 22, height: 22)
                    .background {
                        Circle()
                            .fill(isPillHovered ? MidnightGlass.gold : MidnightGlass.badgeBackground)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(MidnightGlass.gold.opacity(0.88), lineWidth: 1.2)
                    }
                    .onHover { hovering in
                        withAnimation(.snappy(duration: 0.15)) {
                            isPillHovered = hovering
                        }
                    }
                    .opacity(isVisible ? 1 : 0)
                    .scaleEffect(isVisible ? (isPillHovered ? 1.08 : 1.0) : 0.78)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.16)) {
                isZoneHovered = hovering
            }
        }
        .position(tether.severPoint)
        .help("Disconnect \(tether.roomName) from music")
        .accessibilityLabel("Disconnect \(tether.roomName)")
    }
}

private struct BondedSatellitesMapStrip: View {
    var satellites: [BondedSatellite]
    var isPlaying: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(satellites) { sat in
                HStack(spacing: 3) {
                    SpeakerSilhouetteView(
                        model: sat.speakerModel,
                        isOnline: sat.isOnline,
                        isPlaying: isPlaying,
                        isGrouped: true,
                        size: 14
                    )
                    HStack(spacing: 0) {
                        Text(sat.role.shortBadge)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(MidnightGlass.primaryText)
                        Text(" · \(sat.shortModelLabel)")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(MidnightGlass.subtleFill)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(MidnightGlass.cardBorder, lineWidth: 0.75)
                )
                .help("\(sat.role.label) · \(sat.modelLabel) (bonded)")
            }
        }
    }
}

private struct CompactFloorplanMapView: View {
    @Environment(SconeStore.self) private var store
    var nodes: [FloorplanNode]
    var groups: [SonosGroup]
    @Binding var selected: SpeakerUUID?
    var onSelectGroup: ((GroupID) -> Void)?

    private var distinctLevels: [FloorLevel] {
        let levels = Array(Set(nodes.map(\.level))).sorted(by: >)
        return levels.isEmpty ? [.main] : levels
    }

    private var hubGroups: [SonosGroup] {
        deduplicatedActiveHubGroups(from: groups)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                ForEach(distinctLevels) { level in
                    let floorNodes = nodes.filter { $0.level == level }.sorted {
                        if abs($0.coordinate.y - $1.coordinate.y) > 0.10 {
                            return $0.coordinate.y < $1.coordinate.y
                        }
                        return $0.coordinate.x < $1.coordinate.x
                    }
                    let floorHubGroups = hubGroups.filter { group in
                        let memberLevels = group.speakers.compactMap { spk in nodes.first { $0.id == spk.id }?.level }
                        return memberLevels.first == level
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text(level.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MidnightGlass.secondaryText)
                            Spacer()
                            Text("\(floorNodes.count) \(floorNodes.count == 1 ? "Room" : "Rooms")")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MidnightGlass.secondaryText)
                        }
                        .padding(.horizontal, 4)

                        ForEach(floorHubGroups) { hubGroup in
                            MusicSourceNodeView(
                                group: hubGroup,
                                externalSpotify: store.state.externalSpotify,
                                isPlaying: playbackIsActive(hubGroup.playback),
                                isDropTarget: false,
                                flexibleWidth: true,
                                onTogglePlay: {
                                    acousticTick()
                                    store.togglePlayOrHandOffSpotify(for: hubGroup)
                                },
                                onOpenDetail: {
                                    onSelectGroup?(hubGroup.id)
                                }
                            )
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 136), spacing: 10),
                                GridItem(.flexible(minimum: 136), spacing: 10),
                            ],
                            spacing: 10
                        ) {
                            ForEach(floorNodes) { node in
                                sharedFloorRoomNode(node)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(MidnightGlass.floorBandFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(MidnightGlass.floorBandBorder, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private func sharedFloorRoomNode(_ node: FloorplanNode) -> some View {
        let name = RoomNaming.shortName(node.speaker.roomName, merged: false)
        let group = node.group.flatMap { id in groups.first { $0.id == id } }
        let playing = group.map { playbackIsActive($0.playback) } ?? false
        let connectedToHub = group.map { grp in hubGroups.contains { $0.id == grp.id } } ?? false

        return RoomContainerNode(
            node: node,
            name: name,
            playing: playing,
            connectedToHub: connectedToHub,
            isHovered: false,
            isSelected: selected == node.id,
            dropTarget: false,
            flexibleWidth: true
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if let group = node.group {
                onSelectGroup?(group)
            }
        }
        .contextMenu {
            SpeakerGroupContextMenu(group: group, speaker: node.speaker, onOpenGroup: onSelectGroup)
        }
        .draggable(node.id.rawValue)
        .dropDestination(for: String.self) { items, _ in
            joinedSpeaker(from: items, onto: node.id, store: store)
        }
    }
}

private struct DragPreviewTether: View {
    var from: CGPoint
    var to: CGPoint

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            MidnightGlass.gold,
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5])
        )
    }
}

private struct AcousticLink: View {
    var points: [CGPoint]
    var segments: [AcousticCurveSegment]
    var phase: Double?

    var body: some View {
        let path = acousticPath(through: segments)
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { item in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [MidnightGlass.gold.opacity(0.32), MidnightGlass.copper.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 28
                        )
                    )
                    .frame(width: 56, height: 56)
                    .position(item.element)
            }
            path
                .stroke(MidnightGlass.copper.opacity(0.20), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .blur(radius: 4)
            path
                .stroke(
                    LinearGradient(
                        colors: [MidnightGlass.copper, MidnightGlass.gold],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
            if let phase {
                path
                    .trim(from: phase > 0.2 ? phase - 0.2 : 0, to: min(phase, 1))
                    .stroke(MidnightGlass.gold, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            }
        }
    }
}

private func acousticPath(through segments: [AcousticCurveSegment]) -> Path {
    var path = Path()
    guard let first = segments.first else { return path }
    path.move(to: first.start)
    for segment in segments {
        if path.currentPoint != segment.start {
            path.move(to: segment.start)
        }
        path.addQuadCurve(to: segment.end, control: segment.control)
    }
    return path
}

private struct FloorBandsBackdrop: View {
    var bands: [FloorBandLayout]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(bands) { band in
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(MidnightGlass.floorBandFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(MidnightGlass.floorBandBorder, lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        Text(band.level.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .padding(.leading, 18)
                            .padding(.top, 12)
                    }
                    .frame(width: band.frame.width, height: band.frame.height)
                    .position(x: band.frame.midX, y: band.frame.midY)
            }
        }
    }
}
