import Foundation
import SconeDomain
@testable import SonosProtocolBoundary
@testable import SpotifyBridge
import Testing
@testable import SconeStore

private enum House {
    static let kitchen = SpeakerUUID(rawValue: "RINCON_F0F6C1AAD22801400")!
    static let dining = SpeakerUUID(rawValue: "RINCON_F0F6C1C47CEA01400")!
    static let living = SpeakerUUID(rawValue: "RINCON_542A1B95A13A01400")!
    static let bedroom = SpeakerUUID(rawValue: "RINCON_542A1B5F088401400")!
    static let guest = SpeakerUUID(rawValue: "RINCON_542A1B5F08A001400")!
    static let basement = SpeakerUUID(rawValue: "RINCON_C4387523117601400")!
    static let household = HouseholdID(rawValue: "Sonos_HomeHouseholdA1B2C3D4E5")!
}

private enum Office {
    static let speaker = SpeakerUUID(rawValue: "RINCON_38420B1F2E3D01400")!
    static let household = HouseholdID(rawValue: "Sonos_OfficeHouseholdF6E5D4C3")!
}

struct VolumeTests {
    @Test(arguments: [
        (22, DiscreteVolume.v22),
        (23, DiscreteVolume.v23),
        (0, DiscreteVolume.v0),
        (100, DiscreteVolume.v100),
        (-4, DiscreteVolume.v0),
        (140, DiscreteVolume.v100),
        (2, DiscreteVolume.v2),
        (3, DiscreteVolume.v3),
    ])
    func snapsPercent(_ percent: Int, to expected: DiscreteVolume) {
        #expect(DiscreteVolume(snappingPercent: percent) == expected)
    }

    @Test func snapsFractionAndStepsByOnePercentDetents() {
        #expect(DiscreteVolume(snappingFraction: 0.22) == .v22)
        #expect(DiscreteVolume(snappingFraction: 0.226) == .v23)
        #expect(DiscreteVolume(snappingFraction: 1.4) == .v100)
        #expect(DiscreteVolume(snappingFraction: -0.2) == .v0)
        #expect(DiscreteVolume(snappingFraction: .nan) == .v0)
        #expect(DiscreteVolume(snappingFraction: .infinity) == .v0)
        #expect(DiscreteVolume.v0.stepped(by: -1) == .v0)
        #expect(DiscreteVolume.v100.stepped(by: 1) == .v100)
        #expect(DiscreteVolume.v99.stepped(by: 1) == .v100)
        #expect(DiscreteVolume.v20.stepped(by: 3) == .v23)
        #expect(DiscreteVolume.v20.stepped(by: -25) == .v0)
        #expect(DiscreteVolume.v50.stepped(by: 0) == .v50)
    }
}

struct RoomNamingTests {
    @Test(arguments: [
        ("Kitchen Speaker", false, "Kitchen"),
        ("Kitchen Speaker", true, "Kitchen"),
        ("Living Room Soundbar", false, "Living Room"),
        ("Living Room Soundbar", true, "Living"),
        ("Dining Room Speaker", false, "Dining Room"),
        ("Dining Room Speaker", true, "Dining"),
        ("Guest Room Speaker", true, "Guest"),
        ("Living Room", true, "Living"),
        ("Basement Speaker", false, "Basement"),
        (" Speaker", false, " Speaker"),
    ])
    func shortName(_ zone: String, merged: Bool, expected: String) {
        #expect(RoomNaming.shortName(zone, merged: merged) == expected)
    }

    @Test(arguments: [
        ("Living Room Soundbar", [] as [String], 6, "Living Room"),
        ("Dining Room Speaker", [] as [String], 1, "Dining Room"),
        ("Kitchen Speaker", ["Dining Room Speaker"], 6, "Kitchen + Dining"),
        ("Kitchen Speaker", ["Dining Room Speaker", "Bedroom Speaker"], 6, "Kitchen + Bedroom + Dining"),
        (
            "Kitchen Speaker",
            ["Basement Speaker", "Bedroom Speaker", "Guest Room Speaker", "Dining Room Speaker"],
            6,
            "Kitchen + Basement + 3 more"
        ),
        (
            "Living Room Soundbar",
            [
                "Kitchen Speaker", "Dining Room Speaker", "Bedroom Speaker",
                "Guest Room Speaker", "Basement Speaker",
            ],
            6,
            "Everywhere"
        ),
        ("Kitchen Speaker", ["Dining Room Speaker"], 2, "Everywhere"),
        ("Zoo Speaker", ["Alpha Speaker"], 6, "Zoo + Alpha"),
        ("Living Room Soundbar", ["Living Speaker"], 6, "Living Room + Living"),
        ("Kitchen Speaker", ["Living Room Soundbar", "Living Speaker"], 6, "Kitchen + Living + Living Room"),
    ])
    func groupName(coordinator: String, members: [String], online: Int, expected: String) {
        #expect(RoomNaming.groupName(coordinator: coordinator, members: members, onlineRoomCount: online) == expected)
    }
}

struct TopologyTests {
    @Test func standaloneRoomsStayKeysAndJoinedRoomsDoNot() {
        let alone = topology(alone([House.kitchen, House.dining]))
        #expect(alone.groups[GroupID(coordinator: House.kitchen)] == [])
        #expect(alone.groups[GroupID(coordinator: House.dining)] == [])
        let joined = alone.applying(.join(House.dining, coordinator: House.kitchen))
        #expect(joined.groups[GroupID(coordinator: House.kitchen)] == [House.dining])
        #expect(joined.groups[GroupID(coordinator: House.dining)] == nil)
        #expect(joined.group(of: House.dining) == GroupID(coordinator: House.kitchen))
    }

    @Test func stepsThatCannotApplyLeaveTheTopologyAlone() {
        let alone = topology(alone([House.kitchen, House.dining]))
        let joined = alone.applying(.join(House.dining, coordinator: House.kitchen))
        #expect(alone.applying(.makeStandalone(House.basement)) == alone)
        #expect(alone.applying(.join(House.basement, coordinator: House.kitchen)) == alone)
        #expect(alone.applying(.join(House.dining, coordinator: House.basement)) == alone)
        #expect(alone.applying(.join(House.kitchen, coordinator: House.kitchen)) == alone)
        #expect(joined.applying(.join(House.kitchen, coordinator: House.dining)) == joined)
    }

    @Test func aLeavingCoordinatorPromotesTheLowestRemainingMember() {
        let start = topology([
            House.kitchen: House.kitchen,
            House.bedroom: House.kitchen,
            House.guest: House.kitchen,
            House.dining: House.dining,
        ])
        let left = start.applying(.makeStandalone(House.kitchen))
        #expect(left.groups[GroupID(coordinator: House.bedroom)] == [House.guest])
        #expect(left.groups[GroupID(coordinator: House.kitchen)] == [])
        #expect(left.groups[GroupID(coordinator: House.dining)] == [])

        let joined = start.applying(.join(House.kitchen, coordinator: House.dining))
        #expect(joined.groups[GroupID(coordinator: House.dining)] == [House.kitchen])
        #expect(joined.groups[GroupID(coordinator: House.bedroom)] == [House.guest])
    }

    @Test func exactGroupPlanJoinsSortsReleasesAndStaysIdempotent() {
        let alone = topology(alone([House.kitchen, House.dining, House.bedroom]))
        let gather = TopologyTarget.exactGroup(coordinator: House.kitchen, members: [House.dining, House.bedroom])
        #expect(gather.plan(from: alone) == .steps([
            .join(House.bedroom, coordinator: House.kitchen),
            .join(House.dining, coordinator: House.kitchen),
        ], skipped: []))
        expectIdempotent(gather, from: alone)
        let gathered = alone
            .applying(.join(House.bedroom, coordinator: House.kitchen))
            .applying(.join(House.dining, coordinator: House.kitchen))
        #expect(gathered.groups[GroupID(coordinator: House.kitchen)] == [House.bedroom, House.dining])

        let release = TopologyTarget.exactGroup(coordinator: House.kitchen, members: [House.dining])
        #expect(release.plan(from: gathered) == .steps([.makeStandalone(House.bedroom)], skipped: []))
        expectIdempotent(release, from: gathered)

        let visiting = topology([
            House.dining: House.dining,
            House.kitchen: House.dining,
            House.bedroom: House.dining,
        ])
        let kitchenLeadsDining = TopologyTarget.exactGroup(coordinator: House.kitchen, members: [House.dining])
        #expect(kitchenLeadsDining.plan(from: visiting) == .steps([
            .makeStandalone(House.kitchen),
            .join(House.dining, coordinator: House.kitchen),
        ], skipped: []))
        expectIdempotent(kitchenLeadsDining, from: visiting)
        let ended = visiting
            .applying(.makeStandalone(House.kitchen))
            .applying(.join(House.dining, coordinator: House.kitchen))
        #expect(ended.groups[GroupID(coordinator: House.kitchen)] == [House.dining])
        #expect(ended.groups[GroupID(coordinator: House.bedroom)] == [])
    }

    @Test func offlinePresetMembersAreSkippedAndAMissingCoordinatorIsImpossible() {
        let kitchenOnly = topology(alone([House.kitchen]))
        let target = TopologyTarget.exactGroup(coordinator: House.kitchen, members: [House.dining])
        #expect(target.plan(from: kitchenOnly) == .steps([], skipped: [House.dining]))
        #expect(target.isSatisfied(by: kitchenOnly, ignoring: [House.dining]))
        #expect(!target.isSatisfied(by: kitchenOnly))
        #expect(target.plan(from: kitchenOnly) == .steps([], skipped: [House.dining]))

        let missing = TopologyTarget.exactGroup(coordinator: House.dining, members: [House.kitchen])
        #expect(missing.plan(from: kitchenOnly) == .impossible(.coordinatorMissing(House.dining)))
    }

    @Test func memberOfAndStandalonePlansMatchTheEndState() {
        let diningLeads = topology([
            House.dining: House.dining,
            House.kitchen: House.dining,
            House.bedroom: House.bedroom,
        ])
        let joinBedroom = TopologyTarget.memberOf(GroupID(coordinator: House.dining), member: House.bedroom)
        #expect(joinBedroom.plan(from: diningLeads) == .steps([
            .join(House.bedroom, coordinator: House.dining),
        ], skipped: []))
        expectIdempotent(joinBedroom, from: diningLeads)

        let already = TopologyTarget.memberOf(GroupID(coordinator: House.dining), member: House.kitchen)
        #expect(already.plan(from: diningLeads) == .steps([], skipped: []))
        #expect(already.isSatisfied(by: diningLeads))

        let dissolved = TopologyTarget.memberOf(GroupID(coordinator: House.kitchen), member: House.bedroom)
        #expect(dissolved.plan(from: diningLeads) == .impossible(.groupDissolved(GroupID(coordinator: House.kitchen))))

        let ungroup = TopologyTarget.standalone(House.dining)
        #expect(ungroup.plan(from: diningLeads) == .steps([
            .delegateCoordination(from: House.dining, to: House.kitchen, rejoinGroup: false),
        ], skipped: []))
        expectIdempotent(ungroup, from: diningLeads)
        let apart = diningLeads.applying(.delegateCoordination(from: House.dining, to: House.kitchen, rejoinGroup: false))
        #expect(apart.groups[GroupID(coordinator: House.dining)] == [])
        #expect(apart.groups[GroupID(coordinator: House.kitchen)] == [])

        let alreadyAlone = TopologyTarget.standalone(House.bedroom)
        #expect(alreadyAlone.plan(from: diningLeads) == .steps([], skipped: []))

        let gone = TopologyTarget.standalone(House.basement)
        #expect(gone.plan(from: diningLeads) == .steps([], skipped: [House.basement]))
        #expect(gone.isSatisfied(by: diningLeads, ignoring: [House.basement]))
        #expect(gone.plan(from: diningLeads) == .steps([], skipped: [House.basement]))
    }
}

struct FloorplanTests {
    @Test func dynamicTwoFloorHouseholdSeparatesUpperFromLowerAndClustersByWingAndRF() {
        let speakers = [
            speaker(House.basement, room: "Basement Speaker"),
            speaker(House.kitchen, room: "Kitchen Speaker"),
            speaker(House.guest, room: "Guest Room Speaker"),
            speaker(House.living, room: "Living Room Soundbar"),
            speaker(House.bedroom, room: "Bedroom Speaker"),
            speaker(House.dining, room: "Dining Room Speaker"),
        ]
        let layout = FloorplanLayout.infer(speakers: speakers, matrix: .empty)
        #expect(FloorLevel.classify(roomName: "Basement Speaker") == .lower)
        #expect(FloorLevel.classify(roomName: "Kitchen Speaker") == .upper)
        #expect(layout[House.dining] == RoomCoordinate(clampingX: 0.20, y: 0.14))
        #expect(layout[House.kitchen] == RoomCoordinate(clampingX: 0.50, y: 0.14))
        #expect(layout[House.living] == RoomCoordinate(clampingX: 0.80, y: 0.14))
        #expect(layout[House.bedroom] == RoomCoordinate(clampingX: 0.20, y: 0.60))
        #expect(layout[House.guest] == RoomCoordinate(clampingX: 0.80, y: 0.60))
        #expect(layout[House.basement] == RoomCoordinate(clampingX: 0.50, y: 0.81))
        #expect(FloorplanLayout.infer(speakers: [], matrix: .empty).isEmpty)
    }

    @Test func peerBandsQuantizeAndStrongLinksPullBedroomTowardGuest() {
        var matrix = RFPeerMatrix.empty
        matrix.record(House.kitchen, House.kitchen, from: 80, to: 80)
        #expect(matrix.band(House.kitchen, House.kitchen) == nil)
        let rows: [(Int, Int, RFPeerMatrix.Band?)] = [
            (0, 0, nil),
            (-1, -4, nil),
            (19, 1, .weak),
            (20, 1, .moderate),
            (34, 3, .moderate),
            (35, 1, .strong),
            (10, 40, .strong),
        ]
        for (from, to, expected) in rows {
            var sample = RFPeerMatrix.empty
            sample.record(House.bedroom, House.guest, from: from, to: to)
            #expect(sample.band(House.guest, House.bedroom) == expected)
        }

        let pair = [
            speaker(House.bedroom, room: "Bedroom Speaker"),
            speaker(House.guest, room: "Guest Room Speaker"),
        ]
        matrix.record(House.bedroom, House.guest, from: 15, to: 0)
        #expect(matrix.band(House.guest, House.bedroom) == .weak)
        let weak = FloorplanLayout.infer(speakers: pair, matrix: matrix)
        #expect(weak[House.bedroom] == RoomCoordinate(clampingX: 0.20, y: 0.50))
        #expect(weak[House.guest] == RoomCoordinate(clampingX: 0.80, y: 0.50))

        matrix.record(House.guest, House.bedroom, from: 22, to: 20)
        let moderate = FloorplanLayout.infer(speakers: pair, matrix: matrix)
        #expect(moderate[House.bedroom] == RoomCoordinate(clampingX: 0.22, y: 0.50))
        #expect(moderate[House.guest] == RoomCoordinate(clampingX: 0.78, y: 0.50))

        matrix.record(House.bedroom, House.guest, from: 42, to: 43)
        matrix.record(House.bedroom, House.guest, from: 10, to: 12)
        #expect(matrix.band(House.bedroom, House.guest) == .strong)
        let strong = FloorplanLayout.infer(speakers: pair, matrix: matrix)
        #expect(strong[House.bedroom] == RoomCoordinate(clampingX: 0.25, y: 0.50))
        #expect(strong[House.guest] == RoomCoordinate(clampingX: 0.75, y: 0.50))
    }

    @Test func unknownRoomsLandOnASortedGridAndStrongLinksNudgeThem() {
        let first = SpeakerUUID(rawValue: "RINCON_00000000000101400")!
        let second = SpeakerUUID(rawValue: "RINCON_00000000000201400")!
        let firstSpeaker = speaker(first, room: "Studio Alpha")
        let secondSpeaker = speaker(second, room: "Studio Beta")
        let reversed = FloorplanLayout.infer(speakers: [secondSpeaker, firstSpeaker], matrix: .empty)
        #expect(reversed[first] == RoomCoordinate(clampingX: 0.20, y: 0.50))
        #expect(reversed[second] == RoomCoordinate(clampingX: 0.80, y: 0.50))
        #expect(FloorplanLayout.infer(speakers: [firstSpeaker], matrix: .empty)[first] == RoomCoordinate(clampingX: 0.50, y: 0.50))

        var matrix = RFPeerMatrix.empty
        matrix.record(House.kitchen, first, from: 40, to: 36)
        let nudged = FloorplanLayout.infer(
            speakers: [firstSpeaker, speaker(House.kitchen, room: "Studio Gamma")],
            matrix: matrix
        )
        #expect(nudged[first] == RoomCoordinate(clampingX: 0.25, y: 0.50))
        #expect(nudged[House.kitchen] == RoomCoordinate(clampingX: 0.75, y: 0.50))
    }

    @Test func dynamicMultiStoryFloorClassificationSupportsOneTwoAndThreePlusFloors() {
        let singleStory = [
            speaker(House.kitchen, room: "Kitchen Speaker"),
            speaker(House.dining, room: "Dining Room Speaker"),
            speaker(House.living, room: "Living Room Soundbar"),
        ]
        let singleFloors = FloorplanLayout.classifyFloors(speakers: singleStory, matrix: .empty)
        #expect(Set(singleFloors.values).count == 1)
        #expect(singleFloors[House.kitchen]?.title == "Main Floor")

        let thirdFloor = SpeakerUUID(rawValue: "RINCON_00000000000301400")!
        let threeStory = [
            speaker(House.basement, room: "Basement Speaker"),
            speaker(House.kitchen, room: "Kitchen Speaker"),
            speaker(House.bedroom, room: "Upstairs Primary Bedroom"),
        ]
        let threeFloors = FloorplanLayout.classifyFloors(speakers: threeStory, matrix: .empty)
        #expect(Set(threeFloors.values).count == 3)
        #expect(threeFloors[House.bedroom] == .upper)
        #expect(threeFloors[House.kitchen] == .main)
        #expect(threeFloors[House.basement] == .lower)

        let fourStory = threeStory + [speaker(thirdFloor, room: "3rd Floor Penthouse Loft")]
        let multiFloors = FloorplanLayout.classifyFloors(speakers: fourStory, matrix: .empty)
        let distinctLevels = Set(multiFloors.values).sorted(by: >)
        #expect(distinctLevels.count == 4)
        #expect(multiFloors[thirdFloor]?.rank == 4)
        #expect(multiFloors[House.bedroom]?.rank == 3)
        #expect(multiFloors[House.kitchen]?.rank == 2)
        #expect(multiFloors[House.basement]?.rank == 1)
    }

    @Test func roomClusteringGroupsCoLocatedSpeakersAndSeparatesDistinctRoomsByFloor() {
        let kitchenAux = SpeakerUUID(rawValue: "RINCON_00000000000901400")!
        let speakers = [
            speaker(House.kitchen, room: "Kitchen Speaker"),
            speaker(kitchenAux, room: "Kitchen Speaker"),
            speaker(House.dining, room: "Dining Room Speaker"),
            speaker(House.basement, room: "Basement Speaker"),
        ]
        var matrix = RFPeerMatrix.empty
        matrix.record(House.kitchen, kitchenAux, from: 56, to: 55)
        let levels = FloorplanLayout.classifyFloors(speakers: speakers, matrix: matrix)
        let coords = FloorplanLayout.infer(speakers: speakers, matrix: matrix)
        let nodes = speakers.map { spk in
            FloorplanNode(
                speaker: spk,
                level: levels[spk.id] ?? .main,
                coordinate: coords[spk.id] ?? RoomCoordinate(clampingX: 0.5, y: 0.5),
                placement: .inferred,
                group: GroupID(coordinator: spk.id)
            )
        }
        let clusters = FloorplanLayout.clusterRooms(nodes: nodes, matrix: matrix)
        #expect(clusters.count == 3)
        let kitchenCluster = clusters.first { $0.nodes.contains(where: { $0.id == House.kitchen }) }
        #expect(kitchenCluster?.nodes.contains(where: { $0.id == kitchenAux }) == true)
        #expect(kitchenCluster?.nodes.contains(where: { $0.id == House.basement }) == false)
    }

    @Test func floorBandLayoutClampsEveryCoordinateAndSatelliteWithinSafeInnerBounds() throws {
        let satL = BondedSatellite(
            id: SpeakerUUID(rawValue: "RINCON_F0F6C1AAF58601400")!,
            parentID: House.living,
            role: .rearLeft,
            modelNumber: "S39",
            displayName: "Sonos Era 100",
            isOnline: true,
            linkQuality: 63
        )
        let satR = BondedSatellite(
            id: SpeakerUUID(rawValue: "RINCON_C43875987BB201400")!,
            parentID: House.living,
            role: .rearRight,
            modelNumber: "S39",
            displayName: "Sonos Era 100",
            isOnline: true,
            linkQuality: 63
        )
        let livingSpeaker = Speaker(
            id: House.living,
            roomName: "Living Room Soundbar",
            model: .beam,
            reachability: .online(ip: "192.168.68.92", rssi: nil, noiseFloor: nil),
            volume: .v25,
            bondedSatellites: [satL, satR]
        )
        let basementSpeaker = speaker(House.basement, room: "Basement Speaker")
        let extremeNodes = [
            FloorplanNode(
                speaker: livingSpeaker,
                level: .upper,
                coordinate: RoomCoordinate(clampingX: 0.99, y: 0.01),
                placement: .pinned,
                group: GroupID(coordinator: House.living)
            ),
            FloorplanNode(
                speaker: basementSpeaker,
                level: .lower,
                coordinate: RoomCoordinate(clampingX: 0.01, y: 0.99),
                placement: .pinned,
                group: GroupID(coordinator: House.basement)
            ),
        ]
        let plot = CGRect(x: 24, y: 18, width: 680, height: 520)
        let bands = FloorBandLayout.compute(nodes: extremeNodes, in: plot)
        #expect(bands.count == 2)
        for node in extremeNodes {
            let band = try #require(bands.first { $0.level == node.level })
            let hasSats = !node.speaker.bondedSatellites.isEmpty
            let pt = band.point(for: node.coordinate, hasSatellites: hasSats)
            let halfW = FloorBandLayout.cardSize.width * 0.5
            let topHalfH = FloorBandLayout.cardSize.height * 0.5
            let bottomHalfH = topHalfH + (hasSats ? FloorBandLayout.satelliteExtraHeight * 0.5 : 0)
            #expect(pt.x - halfW >= band.frame.minX)
            #expect(pt.x + halfW <= band.frame.maxX)
            #expect(pt.y - topHalfH >= band.frame.minY + FloorBandLayout.headerHeight - 1)
            #expect(pt.y + bottomHalfH <= band.frame.maxY)
        }
    }

    @Test func genericObstacleAwareCurveRoutingAvoidsCollinearObstaclesForArbitraryNodes() {
        let floorBounds = CGRect(x: 20, y: 20, width: 820, height: 320)

        // Case 1: Horizontal collinear arrangement (A at left, Obstacle at center, B at right)
        let leftA = CGPoint(x: 160, y: 150)
        let midObstacleCenter = CGPoint(x: 430, y: 150)
        let rightB = CGPoint(x: 700, y: 150)
        let obstacleRect = AcousticCurveRouter.nodeObstacleRect(center: midObstacleCenter, hasSatellites: false)

        let segHorizontal = AcousticCurveRouter.routeSegment(
            start: leftA,
            end: rightB,
            obstacles: [obstacleRect],
            bounds: floorBounds
        )
        let clearanceH = AcousticCurveRouter.minObstacleClearance(
            for: segHorizontal,
            paddedObstacles: [obstacleRect.insetBy(dx: -22, dy: -22)]
        )
        #expect(clearanceH >= 0)
        #expect(!obstacleRect.insetBy(dx: -14, dy: -14).contains(segHorizontal.midpoint))

        // Case 2: Diagonal arrangement with an arbitrary obstacle directly on the segment midpoint
        let diagStart = CGPoint(x: 180, y: 95)
        let diagEnd = CGPoint(x: 680, y: 255)
        let diagMid = CGPoint(x: (diagStart.x + diagEnd.x) * 0.5, y: (diagStart.y + diagEnd.y) * 0.5)
        let diagObstacle = AcousticCurveRouter.nodeObstacleRect(center: diagMid, hasSatellites: true)

        let segDiagonal = AcousticCurveRouter.routeSegment(
            start: diagStart,
            end: diagEnd,
            obstacles: [diagObstacle],
            bounds: floorBounds
        )
        let clearanceD = AcousticCurveRouter.minObstacleClearance(
            for: segDiagonal,
            paddedObstacles: [diagObstacle.insetBy(dx: -22, dy: -22)]
        )
        #expect(clearanceD >= 0)
        #expect(!diagObstacle.insetBy(dx: -14, dy: -14).contains(segDiagonal.midpoint))

        // Case 3: Multi-room spatial chain ordering (3+ grouped rooms connect adjacent neighbors)
        let chainSegments = AcousticCurveRouter.routeChain(
            points: [rightB, leftA, midObstacleCenter],
            obstacles: [
                AcousticCurveRouter.nodeObstacleRect(center: leftA, hasSatellites: false),
                obstacleRect,
                AcousticCurveRouter.nodeObstacleRect(center: rightB, hasSatellites: false),
            ],
            bounds: floorBounds
        )
        #expect(chainSegments.count == 2)
        #expect(chainSegments[0].start == leftA)
        #expect(chainSegments[0].end == midObstacleCenter)
        #expect(chainSegments[1].start == midObstacleCenter)
        #expect(chainSegments[1].end == rightB)

        // Case 4: Music Hub placement places the hub coherently near connected speakers without overlapping any room container
        let roomObstacles = [
            AcousticCurveRouter.nodeObstacleRect(center: leftA, hasSatellites: false),
            obstacleRect,
            AcousticCurveRouter.nodeObstacleRect(center: rightB, hasSatellites: false),
        ]
        let hubPoint = AcousticCurveRouter.placeMusicHub(
            connectedPoints: [leftA, rightB],
            roomObstacles: roomObstacles,
            bounds: floorBounds
        )
        let hubRect = AcousticCurveRouter.musicHubRect(center: hubPoint)
        for obs in roomObstacles {
            #expect(!hubRect.intersects(obs))
        }
        #expect(floorBounds.contains(hubRect))
    }

    @Test func upperFloorWithFiveRoomsAndMusicHubHasZeroOverlapsAndFullContainmentAtStandardAndCompactWindowSizes() throws {
        let satL = BondedSatellite(
            id: SpeakerUUID(rawValue: "RINCON_F0F6C1AAF58601400")!,
            parentID: House.living,
            role: .rearLeft,
            modelNumber: "S39",
            displayName: "Sonos Era 100",
            isOnline: true,
            linkQuality: 63
        )
        let satR = BondedSatellite(
            id: SpeakerUUID(rawValue: "RINCON_C43875987BB201400")!,
            parentID: House.living,
            role: .rearRight,
            modelNumber: "S39",
            displayName: "Sonos Era 100",
            isOnline: true,
            linkQuality: 63
        )
        let livingSpeaker = Speaker(
            id: House.living,
            roomName: "Living Room Soundbar",
            model: .beam,
            reachability: .online(ip: "192.168.68.92", rssi: -36, noiseFloor: -98),
            volume: .v25,
            bondedSatellites: [satL, satR]
        )
        let kitchenSpeaker = speaker(House.kitchen, room: "Kitchen Speaker")
        let diningSpeaker = speaker(House.dining, room: "Dining Room Speaker")
        let bedroomSpeaker = speaker(House.bedroom, room: "Bedroom Speaker")
        let guestSpeaker = speaker(House.guest, room: "Guest Room Speaker")
        let basementSpeaker = speaker(House.basement, room: "Basement Speaker")

        let allSpeakers = [kitchenSpeaker, diningSpeaker, livingSpeaker, bedroomSpeaker, guestSpeaker, basementSpeaker]
        let inferredCoords = FloorplanLayout.infer(speakers: allSpeakers, matrix: .empty)

        // Test both inferred coordinates AND tightly clustered user-pinned coordinates
        let pinnedCoords: [SpeakerUUID: RoomCoordinate] = [
            House.kitchen: RoomCoordinate(clampingX: 0.251, y: 0.453),
            House.living: RoomCoordinate(clampingX: 0.440, y: 0.465),
            House.bedroom: RoomCoordinate(clampingX: 0.369, y: 0.506),
            House.dining: RoomCoordinate(clampingX: 0.720, y: 0.450),
            House.guest: RoomCoordinate(clampingX: 0.720, y: 0.480),
            House.basement: RoomCoordinate(clampingX: 0.500, y: 0.810),
        ]

        let windowSizes: [CGSize] = [
            CGSize(width: 1050, height: 670),
            CGSize(width: 1389, height: 948),
            // Also test map viewport after subtracting 310pt sidebar width:
            CGSize(width: 1050 - 310, height: 670),
            CGSize(width: 1389 - 310, height: 948),
        ]

        for coords in [inferredCoords, pinnedCoords] {
            let nodes: [FloorplanNode] = [
                FloorplanNode(
                    speaker: kitchenSpeaker,
                    level: .upper,
                    coordinate: coords[House.kitchen]!,
                    placement: .pinned,
                    group: GroupID(coordinator: House.living)
                ),
                FloorplanNode(
                    speaker: livingSpeaker,
                    level: .upper,
                    coordinate: coords[House.living]!,
                    placement: .pinned,
                    group: GroupID(coordinator: House.living)
                ),
                FloorplanNode(
                    speaker: bedroomSpeaker,
                    level: .upper,
                    coordinate: coords[House.bedroom]!,
                    placement: .pinned,
                    group: GroupID(coordinator: House.bedroom)
                ),
                FloorplanNode(
                    speaker: diningSpeaker,
                    level: .upper,
                    coordinate: coords[House.dining]!,
                    placement: .pinned,
                    group: GroupID(coordinator: House.dining)
                ),
                FloorplanNode(
                    speaker: guestSpeaker,
                    level: .upper,
                    coordinate: coords[House.guest]!,
                    placement: .pinned,
                    group: GroupID(coordinator: House.guest)
                ),
                FloorplanNode(
                    speaker: basementSpeaker,
                    level: .lower,
                    coordinate: coords[House.basement]!,
                    placement: .inferred,
                    group: GroupID(coordinator: House.basement)
                ),
            ]

            for windowSize in windowSizes {
                let plot = CGRect(origin: .zero, size: windowSize).insetBy(dx: 24, dy: 16)
                let bands = FloorBandLayout.compute(
                    nodes: nodes,
                    in: plot,
                    activeHubCountByLevel: [.upper: 1]
                )
                let upperBand = try #require(bands.first { $0.level == .upper })
                let upperNodes = nodes.filter { $0.level == .upper }

                let basePoints = Dictionary(uniqueKeysWithValues: upperNodes.map { node in
                    (node.id, upperBand.point(for: node.coordinate, hasSatellites: !node.speaker.bondedSatellites.isEmpty))
                })
                let initialRoomObstacles = upperNodes.map { node in
                    AcousticCurveRouter.nodeObstacleRect(
                        center: basePoints[node.id]!,
                        hasSatellites: !node.speaker.bondedSatellites.isEmpty
                    )
                }
                let hubBounds = CGRect(
                    x: upperBand.frame.minX + 16,
                    y: upperBand.frame.minY + FloorBandLayout.headerHeight + 8,
                    width: max(80, upperBand.frame.width - 32),
                    height: max(60, upperBand.frame.height - FloorBandLayout.headerHeight - 16)
                )
                let hubID = GroupID(coordinator: House.living)
                let initialHubCenter = AcousticCurveRouter.placeMusicHub(
                    connectedPoints: [basePoints[House.living]!, basePoints[House.kitchen]!],
                    roomObstacles: initialRoomObstacles,
                    bounds: hubBounds
                )

                let roomSpecs = upperNodes.map { node in
                    AcousticCurveRouter.LayoutRoomSpec(
                        id: node.id,
                        center: AcousticCurveRouter.nudgedRoomPoint(
                            basePoint: basePoints[node.id]!,
                            hubCenter: initialHubCenter,
                            safeRect: upperBand.safeInnerRect
                        ),
                        hasSatellites: !node.speaker.bondedSatellites.isEmpty,
                        isFixed: false
                    )
                }
                let resolved = AcousticCurveRouter.resolveBandCollisions(
                    rooms: roomSpecs,
                    hubCenters: [hubID: initialHubCenter],
                    bandFrame: upperBand.frame
                )

                let resolvedHubCenter = try #require(resolved.hubCenters[hubID])
                let resolvedHubRect = AcousticCurveRouter.musicHubRect(center: resolvedHubCenter)
                #expect(resolvedHubRect.width == 340)
                #expect(resolvedHubRect.height == 108)

                var allRects: [(String, CGRect)] = [("MusicHub", resolvedHubRect)]
                for node in upperNodes {
                    let center = try #require(resolved.roomCenters[node.id])
                    let hasSats = !node.speaker.bondedSatellites.isEmpty
                    let rect = AcousticCurveRouter.nodeObstacleRect(center: center, hasSatellites: hasSats)
                    if hasSats {
                        #expect(rect.width == 198)
                        #expect(rect.height == 128)
                    }
                    allRects.append((node.speaker.roomName, rect))
                }

                // 1. 100% containment inside bandFrame inset by 20pt on left/right/bottom and below header
                let safeContainer = CGRect(
                    x: upperBand.frame.minX + 20 - 0.5,
                    y: upperBand.frame.minY + FloorBandLayout.headerHeight - 0.5,
                    width: upperBand.frame.width - 40 + 1.0,
                    height: upperBand.frame.height - FloorBandLayout.headerHeight - 20 + 1.0
                )
                for (label, rect) in allRects {
                    #expect(
                        upperBand.frame.contains(rect),
                        "Expected \(label) (\(rect)) to be 100% inside upperBand.frame (\(upperBand.frame)) at window \(windowSize)"
                    )
                    #expect(
                        safeContainer.contains(rect),
                        "Expected \(label) (\(rect)) to respect >= 20pt inset (\(safeContainer)) at window \(windowSize)"
                    )
                }

                // 2. Zero pairwise overlaps even when padded by 16pt (8pt per rect, and up to 11.5pt per rect = 23pt gap)
                for i in 0..<allRects.count {
                    for j in (i + 1)..<allRects.count {
                        let paddedA = allRects[i].1.insetBy(dx: -8, dy: -8)
                        let paddedB = allRects[j].1.insetBy(dx: -8, dy: -8)
                        #expect(
                            !paddedA.intersects(paddedB),
                            "Collision between \(allRects[i].0) (\(allRects[i].1)) and \(allRects[j].0) (\(allRects[j].1)) at window \(windowSize)"
                        )
                        let strictA = allRects[i].1.insetBy(dx: -11.5, dy: -11.5)
                        let strictB = allRects[j].1.insetBy(dx: -11.5, dy: -11.5)
                        #expect(
                            !strictA.intersects(strictB),
                            "Gap < 23pt between \(allRects[i].0) (\(allRects[i].1)) and \(allRects[j].0) (\(allRects[j].1)) at window \(windowSize)"
                        )
                    }
                }
            }
        }
    }
}

struct BondedSatelliteAndTelemetryTests {
    @Test func classifiesEra100SatellitesFromDeviceDescriptionAndParsesZoneGroupState() throws {
        let satLeftID = SpeakerUUID(rawValue: "RINCON_F0F6C1AAF58601400")!
        let satRightID = SpeakerUUID(rawValue: "RINCON_C43875987BB201400")!

        let era100Desc = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <modelNumber>S39</modelNumber>
            <modelName>Sonos Era 100</modelName>
            <displayName>Era 100</displayName>
            <UDN>uuid:RINCON_F0F6C1AAF58601400</UDN>
          </device>
        </root>
        """.utf8)
        let parsedDesc = try TelemetryService.parseDeviceDescription(era100Desc)
        #expect(parsedDesc.modelNumber == "S39")
        #expect(parsedDesc.displayName == "Sonos Era 100")
        #expect(SpeakerModel.classify(modelName: parsedDesc.displayName, modelNumber: parsedDesc.modelNumber) == SpeakerModel.era100)

        let satLeft = BondedSatellite(
            id: satLeftID,
            parentID: House.living,
            role: .rearLeft,
            modelNumber: parsedDesc.modelNumber,
            displayName: parsedDesc.displayName,
            isOnline: true,
            linkQuality: 63
        )
        #expect(satLeft.speakerModel == SpeakerModel.era100)
        #expect(satLeft.modelLabel == "Sonos Era 100")

        let zgsXML = """
        <ZoneGroupState>
          <ZoneGroups>
            <ZoneGroup Coordinator="RINCON_542A1B95A13A01400" ID="RINCON_542A1B95A13A01400:1">
              <ZoneGroupMember UUID="RINCON_542A1B95A13A01400"
                               Location="http://192.168.68.92:1400/xml/device_description.xml"
                               ZoneName="Living Room Soundbar"
                               HTSatChanMapSet="RINCON_542A1B95A13A01400:LF,RF;RINCON_F0F6C1AAF58601400:LR,LTR;RINCON_C43875987BB201400:RR,RTR">
                <Satellite UUID="RINCON_F0F6C1AAF58601400"
                           Location="http://192.168.68.72:1400/xml/device_description.xml"
                           HTSatChanMapSet="RINCON_542A1B95A13A01400:LF,RF;RINCON_F0F6C1AAF58601400:LR,LTR" />
                <Satellite UUID="RINCON_C43875987BB201400"
                           Location="http://192.168.68.83:1400/xml/device_description.xml"
                           HTSatChanMapSet="RINCON_542A1B95A13A01400:LF,RF;RINCON_C43875987BB201400:RR,RTR" />
              </ZoneGroupMember>
            </ZoneGroup>
          </ZoneGroups>
        </ZoneGroupState>
        """
        let parsedTopology = try TopologyService.parse(zoneGroupState: zgsXML, household: House.household)
        #expect(parsedTopology.members.count == 1)
        let beamMember = try #require(parsedTopology.members[House.living])
        #expect(beamMember.satellites.count == 2)
        #expect(beamMember.satellites[0].id == satLeftID)
        #expect(beamMember.satellites[0].role == SatelliteRole.rearLeft)
        #expect(beamMember.satellites[0].endpoint?.host == "192.168.68.72")
        #expect(beamMember.satellites[1].id == satRightID)
        #expect(beamMember.satellites[1].role == SatelliteRole.rearRight)
        #expect(beamMember.satellites[1].endpoint?.host == "192.168.68.83")
    }
}

struct SpeakerModelClassificationTests {
    @Test(arguments: [
        // Soundbars
        ("Sonos Arc", "S19", SpeakerModel.arc),
        ("Sonos Arc Ultra", "S45", SpeakerModel.arc),
        ("Sonos Beam", "S14", SpeakerModel.beam),
        ("Sonos Beam", "S31", SpeakerModel.beam),
        ("Sonos Ray", "S36", SpeakerModel.ray),
        ("Sonos Playbar", "S9", SpeakerModel.playbar),
        ("Sonos Playbase", "S11", SpeakerModel.playbase),
        // Smart & Room Speakers
        ("Sonos Era 100", "S39", SpeakerModel.era100),
        ("Sonos Era 300", "S41", SpeakerModel.era300),
        ("Sonos One", "S13", SpeakerModel.one),
        ("Sonos One", "S18", SpeakerModel.one),
        ("Sonos One SL", "S22", SpeakerModel.one),
        ("Sonos One SL", "S38", SpeakerModel.one),
        ("Sonos Play:5", "S5", SpeakerModel.five),
        ("Sonos Play:5", "S6", SpeakerModel.five),
        ("Sonos Five", "S23", SpeakerModel.five),
        ("Sonos Play:1", "S1", SpeakerModel.play1),
        ("Sonos Play:1", "S12", SpeakerModel.play1),
        ("Sonos Play:3", "S3", SpeakerModel.play3),
        // Portables
        ("Sonos Move", "S17", SpeakerModel.move(battery: nil)),
        ("Sonos Move 2", "S44", SpeakerModel.move(battery: nil)),
        ("Sonos Roam", "S27", SpeakerModel.roam(battery: nil)),
        ("Sonos Roam SL", "S35", SpeakerModel.roam(battery: nil)),
        ("Sonos Roam 2", "S43", SpeakerModel.roam(battery: nil)),
        // Subwoofers
        ("Sonos Sub", "S10", SpeakerModel.sub),
        ("Sonos Sub", "S15", SpeakerModel.sub),
        ("Sonos Sub (Gen 3)", "S24", SpeakerModel.sub),
        ("Sonos Sub", "S37", SpeakerModel.sub),
        ("Sonos Sub 4", "S42", SpeakerModel.sub),
        ("Sonos Sub", "SUB", SpeakerModel.sub),
        ("Sonos Sub Mini", "S34", SpeakerModel.subMini),
        // IKEA SYMFONISK
        ("SYMFONISK Bookshelf", "S21", SpeakerModel.symfoniskBookshelf),
        ("SYMFONISK Bookshelf", "S33", SpeakerModel.symfoniskBookshelf),
        ("SYMFONISK Table Lamp", "S20", SpeakerModel.symfoniskLamp),
        ("SYMFONISK Table Lamp", "S29", SpeakerModel.symfoniskLamp),
        ("SYMFONISK Floor Lamp", "S40", SpeakerModel.symfoniskLamp),
        ("SYMFONISK Picture Frame", "S30", SpeakerModel.symfoniskFrame),
        // Components / Amps
        ("Sonos Amp", "S16", SpeakerModel.amp),
        ("Sonos Connect:Amp", "ZP100", SpeakerModel.amp),
        ("Sonos Connect:Amp", "ZP120", SpeakerModel.amp),
        ("Sonos Port", "S23", SpeakerModel.port),
        ("Sonos Connect", "ZP80", SpeakerModel.port),
        ("Sonos Connect", "ZP90", SpeakerModel.port),
    ])
    func classifiesEntireSonosLineupByModelNumberAndName(
        modelName: String,
        modelNumber: String,
        expected: SpeakerModel
    ) {
        #expect(SpeakerModel.classify(modelName: modelName, modelNumber: modelNumber) == expected)
        #expect(!expected.displayName.isEmpty)
        #expect(!expected.shortName.isEmpty)
    }

    @Test func portableModelsPreserveBatteryTelemetryAndIdentifyBatteryCapability() {
        let bat = BatteryTelemetry(
            levelPercent: 84,
            isOnCharger: true,
            temperatureCelsius: 26,
            sampledAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        #expect(SpeakerModel.classify(modelName: "Sonos Move", modelNumber: "S17", battery: bat) == .move(battery: bat))
        #expect(SpeakerModel.classify(modelName: "Sonos Move 2", modelNumber: "S44", battery: bat) == .move(battery: bat))
        #expect(SpeakerModel.classify(modelName: "Sonos Roam", modelNumber: "S27", battery: bat) == .roam(battery: bat))
        #expect(SpeakerModel.classify(modelName: "Sonos Roam 2", modelNumber: "S43", battery: bat).battery == bat)

        for portableCode in ["S17", "S44", "S27", "S35", "S43"] {
            #expect(SpeakerModel.isBatteryCapable(modelNumber: portableCode))
        }
        for mainsCode in ["S19", "S31", "S39", "S41", "S16", "S24"] {
            #expect(!SpeakerModel.isBatteryCapable(modelNumber: mainsCode))
        }
    }
}

struct TokenVaultSecurityTests {
    @Test func tokenVaultEncryptsTokensOnDiskWithOwnerOnlyPermissions() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = "com.sconeos.tests.vault.\(UUID().uuidString)"
        let vault = TokenVault(service: service, directory: dir)

        let secretAccess = "secret_access_token_\(UUID().uuidString)"
        let secretRefresh = "secret_refresh_token_\(UUID().uuidString)"
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)

        vault.store(refreshToken: secretRefresh)
        vault.store(accessToken: secretAccess, expiry: expiry)
        vault.storeDisplayName("Dylan Gattey")

        #expect(vault.refreshToken() == secretRefresh)
        let loadedAccess = try #require(vault.accessToken())
        #expect(loadedAccess.token == secretAccess)
        #expect(loadedAccess.expiry == expiry)
        #expect(vault.displayName() == "Dylan Gattey")

        // Verify a second TokenVault instance pointing at the same directory restores tokens and displayName immediately
        let reopenedVault = TokenVault(service: service, directory: dir)
        #expect(reopenedVault.refreshToken() == secretRefresh)
        #expect(reopenedVault.accessToken()?.token == secretAccess)
        #expect(reopenedVault.displayName() == "Dylan Gattey")

        let vaultFile = dir.appending(path: "spotify-vault.enc")
        let ciphertext = try Data(contentsOf: vaultFile)
        let rawString = String(decoding: ciphertext, as: UTF8.self)
        #expect(!rawString.contains(secretAccess))
        #expect(!rawString.contains(secretRefresh))

        let attrs = try FileManager.default.attributesOfItem(atPath: vaultFile.path)
        let posix = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(posix == 0o600)

        vault.clear()
        #expect(vault.refreshToken() == nil)
        #expect(vault.accessToken() == nil)
        #expect(!FileManager.default.fileExists(atPath: vaultFile.path))
    }

    @Test func sealedClientStoreUnsealsEphemeralClientIDWithoutPersistingPlaintext() {
        let resolvedLength = SealedClientStore.withEphemeralClientID { id in
            id.count
        }
        #expect(resolvedLength == 32)
        let overridden = SealedClientStore.withEphemeralClientID(override: "  custom_client_id_12345  ") { id in
            id
        }
        #expect(overridden == "custom_client_id_12345")
    }
}

struct SpotifyURITests {
    private static let id22 = "0123456789abcdefghijkl"

    @Test(arguments: [
        ("spotify:track:\(id22)", SpotifyURI.Kind.track, id22),
        ("spotify:album:\(id22)", SpotifyURI.Kind.album, id22),
        ("spotify:playlist:\(id22)", SpotifyURI.Kind.playlist, id22),
        ("https://open.spotify.com/track/\(id22)?si=abc&utm=1", SpotifyURI.Kind.track, id22),
        ("https://open.spotify.com/album/\(id22)#start", SpotifyURI.Kind.album, id22),
        ("https://open.spotify.com/playlist/\(id22)/", SpotifyURI.Kind.playlist, id22),
        ("spotify:track:0123456789abcde", SpotifyURI.Kind.track, "0123456789abcde"),
        ("spotify:track:0123456789abcdefghij0123456789", SpotifyURI.Kind.track, "0123456789abcdefghij0123456789"),
    ])
    func accepts(_ raw: String, kind: SpotifyURI.Kind, id: String) {
        let uri = SpotifyURI(raw)
        #expect(uri?.kind == kind)
        #expect(uri?.id == id)
        #expect(uri?.description == "spotify:\(kind.rawValue):\(id)")
    }

    @Test(arguments: [
        "spotify:local:Artist:Album:Title:1",
        "spotify:episode:\(id22)",
        "spotify:show:\(id22)",
        "spotify:track:0123456789abcd",
        "spotify:track:0123456789abcdefghij0123456789x",
        "spotify:track:\(id22):extra",
        "http://open.spotify.com/track/\(id22)",
        "https://open.spotify.com/intl-en/track/\(id22)",
        "https://play.spotify.com/track/\(id22)",
        "Spotify:track:\(id22)",
        "",
    ])
    func rejects(_ raw: String) {
        #expect(SpotifyURI(raw) == nil)
    }
}

struct PlaybackTests {
    @Test func elapsedFollowsTransportAndClampsToTheTrack() {
        let song = NowPlaying.track(NowPlayingTrack(
            title: "Song", artist: "Artist", album: nil, artworkURL: nil,
            duration: .seconds(10), queuePosition: 1, spotifyURI: nil))
        let start = Date(timeIntervalSinceReferenceDate: 10)
        #expect(PlaybackState.stopped.elapsed(at: start) == nil)
        let paused = PlaybackState.paused(song, elapsed: .seconds(4))
        #expect(paused.elapsed(at: Date(timeIntervalSinceReferenceDate: 50)) == .seconds(4))
        let playing = PlaybackState.playing(song, elapsed: .seconds(4), sampledAt: start)
        #expect(playing.elapsed(at: Date(timeIntervalSinceReferenceDate: 13)) == .seconds(7))
        #expect(playing.elapsed(at: Date(timeIntervalSinceReferenceDate: 30)) == .seconds(10))
        #expect(playing.elapsed(at: Date(timeIntervalSinceReferenceDate: 8)) == .seconds(4))
        let radio = PlaybackState.playing(.stream(title: "Radio"), elapsed: .seconds(4), sampledAt: start)
        #expect(radio.elapsed(at: Date(timeIntervalSinceReferenceDate: 30)) == .seconds(24))
    }

    @Test func parsesSpotifyConnectTrackWithRealAlbumArtAndRelativeGetAAURLs() throws {
        let endpoint = URL(string: "http://192.168.68.90:1400/xml/device_description.xml")!
        let vliURI = "x-sonos-vli:RINCON_542A1B5F08A001400:2,spotify:5973be481c0e48efacb7985c9c8fca58"
        let transportInfo = try XMLNode.parse(Data("""
        <GetTransportInfoResponse><CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState></GetTransportInfoResponse>
        """.utf8))
        let mediaInfo = try XMLNode.parse(Data("""
        <GetMediaInfoResponse>
          <CurrentURI>\(vliURI)</CurrentURI>
          <CurrentURIMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;&quot; parentID=&quot;&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;Spotify&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
        </GetMediaInfoResponse>
        """.utf8))
        let positionInfo = try XMLNode.parse(Data("""
        <GetPositionInfoResponse>
          <Track>1</Track>
          <TrackDuration>0:03:44</TrackDuration>
          <TrackMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;res protocolInfo=&quot;sonos.com-spotify:*:audio/x-spotify:*&quot; duration=&quot;0:03:44&quot;&gt;x-sonos-spotify:spotify:track:2mqTtvbKxH7SoEQ2oGAnsA?sid=12&amp;amp;flags=0&amp;amp;sn=3&lt;/res&gt;&lt;upnp:albumArtURI&gt;https://i.scdn.co/image/ab67616d0000b27369a3c061676c2020adfe8315&lt;/upnp:albumArtURI&gt;&lt;dc:title&gt;CHURCH GIRL&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;dc:creator&gt;Beyoncé&lt;/dc:creator&gt;&lt;upnp:album&gt;RENAISSANCE&lt;/upnp:album&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
          <TrackURI>\(vliURI)</TrackURI>
          <RelTime>0:01:47</RelTime>
        </GetPositionInfoResponse>
        """.utf8))
        let parsed = TransportService.parsePlayback(
            transportInfo: transportInfo,
            positionInfo: positionInfo,
            mediaInfo: mediaInfo,
            coordinatorEndpoint: endpoint,
            sampledAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        guard case .paused(.track(let track), let elapsed) = parsed else {
            Issue.record("expected paused track, got \(parsed)")
            return
        }
        #expect(track.title == "CHURCH GIRL")
        #expect(track.artist == "Beyoncé")
        #expect(track.album == "RENAISSANCE")
        #expect(track.artworkURL?.absoluteString == "https://i.scdn.co/image/ab67616d0000b27369a3c061676c2020adfe8315")
        #expect(track.spotifyURI?.description == "spotify:track:2mqTtvbKxH7SoEQ2oGAnsA")
        #expect(track.source == PlaybackSource.spotify(contextTitle: nil))
        #expect(track.canSkip == true)
        #expect(track.isSpotifyConnect)
        #expect(elapsed == .seconds(107))

        let enriched = track.merging(
            artworkURL: nil,
            source: .spotify(contextTitle: "Playlist \"26\""),
            upNext: [
                QueueItem(
                    id: "1",
                    title: "VIRGO'S GROOVE",
                    artist: "Beyoncé",
                    album: "RENAISSANCE",
                    artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b27369a3c061676c2020adfe8315"),
                    duration: .seconds(368),
                    spotifyURI: SpotifyURI("spotify:track:0FlfN5cbUUpIHCRH8X1M44")
                ),
            ]
        )
        #expect(enriched.source?.label == "Playing from Spotify · Playlist \"26\"")
        #expect(enriched.upNext.count == 1)
        #expect(enriched.upNext.first?.title == "VIRGO'S GROOVE")

        let transportPlaying = try XMLNode.parse(Data("""
        <GetTransportInfoResponse><CurrentTransportState>PLAYING</CurrentTransportState></GetTransportInfoResponse>
        """.utf8))
        let mediaRelative = try XMLNode.parse(Data("""
        <GetMediaInfoResponse>
          <CurrentURI>x-rincon-queue:RINCON_542A1B5F08A001400#0</CurrentURI>
          <CurrentURIMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;1006206cspotify%3aplaylist%3a3wdvPfaJKS9AnZzRX35gyW&quot; parentID=&quot;10082664playlists&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;26&lt;/dc:title&gt;&lt;upnp:class&gt;object.container.playlistContainer&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
        </GetMediaInfoResponse>
        """.utf8))
        let positionRelative = try XMLNode.parse(Data("""
        <GetPositionInfoResponse>
          <Track>2</Track>
          <TrackDuration>0:03:44</TrackDuration>
          <TrackMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;res duration=&quot;0:03:44&quot;&gt;x-sonos-spotify:spotify:track:2mqTtvbKxH7SoEQ2oGAnsA?sid=12&amp;amp;flags=8224&amp;amp;sn=3&lt;/res&gt;&lt;upnp:albumArtURI&gt;/getaa?s=1&amp;amp;u=x-sonos-spotify%3Aspotify%3Atrack%3A2mqTtvbKxH7SoEQ2oGAnsA%3Fsid%3D12%26flags%3D8224%26sn%3D3&lt;/upnp:albumArtURI&gt;&lt;dc:title&gt;CHURCH GIRL&lt;/dc:title&gt;&lt;dc:creator&gt;Beyoncé&lt;/dc:creator&gt;&lt;upnp:album&gt;RENAISSANCE&lt;/upnp:album&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
          <TrackURI>x-sonos-spotify:spotify:track:2mqTtvbKxH7SoEQ2oGAnsA?sid=12&amp;flags=8224&amp;sn=3</TrackURI>
          <RelTime>0:00:12</RelTime>
        </GetPositionInfoResponse>
        """.utf8))
        let parsedRelative = TransportService.parsePlayback(
            transportInfo: transportPlaying,
            positionInfo: positionRelative,
            mediaInfo: mediaRelative,
            coordinatorEndpoint: endpoint,
            sampledAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        guard case .playing(.track(let relTrack), _, _) = parsedRelative else {
            Issue.record("expected playing track, got \(parsedRelative)")
            return
        }
        #expect(relTrack.artworkURL?.absoluteString == "http://192.168.68.90:1400/getaa?s=1&u=x-sonos-spotify%3Aspotify%3Atrack%3A2mqTtvbKxH7SoEQ2oGAnsA%3Fsid%3D12%26flags%3D8224%26sn%3D3")
        #expect(relTrack.source == PlaybackSource.spotify(contextTitle: "26"))
        #expect(relTrack.queuePosition == 2)
        #expect(!relTrack.isSpotifyConnect)
    }
}

struct HouseholdTests {
    @Test func groupsNameSortAndSkipACoordinatorTheSweepDidNotSee() {
        let kitchen = speaker(House.kitchen, room: "Kitchen Speaker", volume: .v25)
        let dining = speaker(House.dining, room: "Dining Room Speaker", ip: "192.168.68.71")
        let bedroom = speaker(House.bedroom, room: "Bedroom Speaker", ip: "192.168.68.73")
        let living = speaker(House.living, room: "Living Room Soundbar", ip: "192.168.68.92", volume: .v15)
        let grouped = snapshot(
            [kitchen, dining, bedroom, living],
            coordinatorOf: [
                House.kitchen: House.kitchen,
                House.dining: House.kitchen,
                House.bedroom: House.kitchen,
                House.living: House.living,
            ],
            status: [GroupID(coordinator: House.kitchen): GroupStatus(playback: .stopped, volume: .v40)])
        #expect(grouped.groups.map(\.displayName) == ["Kitchen + Bedroom + Dining", "Living Room"])
        #expect(grouped.groups[0].members.map(\.roomName) == ["Bedroom Speaker", "Dining Room Speaker"])
        #expect(grouped.groups[0].volume == .v40)
        #expect(grouped.groups[1].volume == .v15)

        let partial = snapshot(
            [kitchen],
            coordinatorOf: [
                House.kitchen: House.kitchen,
                House.basement: House.basement,
                House.dining: House.basement,
            ])
        #expect(partial.groups.map(\.displayName) == ["Kitchen"])

        let retargeted = grouped.replacing(
            status: (GroupID(coordinator: House.kitchen), GroupStatus(playback: .stopped, volume: .v55)))
        #expect(retargeted.status(of: GroupID(coordinator: House.kitchen)).volume == .v55)
        #expect(retargeted.observedAt == grouped.observedAt)
    }

    @Test func suppressesStalePausedSessionsWhenAnotherGroupIsPlayingAndDeduplicatesPausedSessions() throws {
        let notoriousTrack = NowPlayingTrack(
            title: "Notorious",
            artist: "Collect 200",
            album: "Collect 200",
            artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b2731234"),
            duration: .seconds(210),
            queuePosition: 1,
            spotifyURI: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA"),
            source: .spotify(contextTitle: "Playlist \"26\"")
        )
        let otherSpotifyTrack = NowPlayingTrack(
            title: "Creep",
            artist: "Radiohead",
            album: "Pablo Honey",
            artworkURL: nil,
            duration: .seconds(238),
            queuePosition: 2,
            spotifyURI: SpotifyURI("spotify:track:70LcF31zb1H0PyJoS1Sx1r"),
            source: .spotify(contextTitle: "Liked Songs")
        )
        let livingGroup = GroupID(coordinator: House.living)
        let bedroomGroup = GroupID(coordinator: House.bedroom)
        let kitchenGroup = GroupID(coordinator: House.kitchen)
        let now = Date(timeIntervalSinceReferenceDate: 5_000)

        // 1. Living Room is .playing "Notorious · Collect 200" while Bedroom has a leftover .paused
        // "Notorious · Collect 200" and Kitchen has a leftover .paused Spotify track.
        // Only Living Room may retain an active session; Bedroom and Kitchen must be cleared to .stopped!
        let playingVsPaused = snapshot(
            [
                speaker(House.living, room: "Living Room"),
                speaker(House.bedroom, room: "Bedroom"),
                speaker(House.kitchen, room: "Kitchen"),
            ],
            coordinatorOf: [
                House.living: House.living,
                House.bedroom: House.bedroom,
                House.kitchen: House.kitchen,
            ],
            status: [
                livingGroup: GroupStatus(
                    playback: .playing(.track(notoriousTrack), elapsed: .seconds(48), sampledAt: now),
                    volume: .v30
                ),
                bedroomGroup: GroupStatus(
                    playback: .paused(.track(notoriousTrack), elapsed: .seconds(15)),
                    volume: .v20
                ),
                kitchenGroup: GroupStatus(
                    playback: .paused(.track(otherSpotifyTrack), elapsed: .seconds(90)),
                    volume: .v25
                ),
            ],
            at: now
        )

        #expect(playingVsPaused.status(of: livingGroup).playback == .playing(.track(notoriousTrack), elapsed: .seconds(48), sampledAt: now))
        #expect(playingVsPaused.status(of: bedroomGroup).playback == .stopped)
        #expect(playingVsPaused.status(of: kitchenGroup).playback == .stopped)

        // 2. When NO group is .playing and multiple ungrouped rooms report the same .paused track,
        // only ONE group (preferring the larger group or preferred coordinator) retains the .paused session!
        let allPaused = HouseholdSnapshot(
            household: House.household,
            observedAt: now,
            speakers: Dictionary(uniqueKeysWithValues: [
                speaker(House.living, room: "Living Room"),
                speaker(House.dining, room: "Dining Room"),
                speaker(House.bedroom, room: "Bedroom"),
            ].map { ($0.id, $0) }),
            topology: topology([
                House.living: House.living,
                House.dining: House.living,
                House.bedroom: House.bedroom,
            ]),
            groupStatus: [
                livingGroup: GroupStatus(
                    playback: .paused(.track(notoriousTrack), elapsed: .seconds(60)),
                    volume: .v30
                ),
                bedroomGroup: GroupStatus(
                    playback: .paused(.track(notoriousTrack), elapsed: .seconds(60)),
                    volume: .v20
                ),
            ],
            rf: .empty
        )

        #expect(allPaused.status(of: livingGroup).playback == .paused(.track(notoriousTrack), elapsed: .seconds(60)))
        #expect(allPaused.status(of: bedroomGroup).playback == .stopped)

        // 3. When TransportService parses STOPPED with leftover Spotify metadata in GetPositionInfo,
        // it must return .stopped instead of .paused.
        let endpoint = URL(string: "http://192.168.68.90:1400/xml/device_description.xml")!
        let stoppedTransport = try XMLNode.parse(Data("""
        <GetTransportInfoResponse><CurrentTransportState>STOPPED</CurrentTransportState></GetTransportInfoResponse>
        """.utf8))
        let mediaInfo = try XMLNode.parse(Data("""
        <GetMediaInfoResponse>
          <CurrentURI>x-rincon-queue:RINCON_542A1B5F08A001400#0</CurrentURI>
          <CurrentURIMetaData></CurrentURIMetaData>
        </GetMediaInfoResponse>
        """.utf8))
        let positionInfo = try XMLNode.parse(Data("""
        <GetPositionInfoResponse>
          <Track>1</Track>
          <TrackDuration>0:03:30</TrackDuration>
          <TrackMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;res duration=&quot;0:03:30&quot;&gt;x-sonos-spotify:spotify:track:2mqTtvbKxH7SoEQ2oGAnsA?sid=12&amp;amp;flags=8224&amp;amp;sn=3&lt;/res&gt;&lt;dc:title&gt;Notorious&lt;/dc:title&gt;&lt;dc:creator&gt;Collect 200&lt;/dc:creator&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
          <TrackURI>x-sonos-spotify:spotify:track:2mqTtvbKxH7SoEQ2oGAnsA?sid=12&amp;flags=8224&amp;sn=3</TrackURI>
          <RelTime>0:00:48</RelTime>
        </GetPositionInfoResponse>
        """.utf8))
        let parsedStopped = TransportService.parsePlayback(
            transportInfo: stoppedTransport,
            positionInfo: positionInfo,
            mediaInfo: mediaInfo,
            coordinatorEndpoint: endpoint,
            sampledAt: now
        )
        #expect(parsedStopped == .stopped)
    }

    @Test func playingSnapshotsWithLinearClockProgressionAreSemanticallyEquivalent() {
        let track = NowPlayingTrack(
            title: "Notorious",
            artist: "Collect 200",
            album: nil,
            artworkURL: nil,
            duration: .seconds(210),
            queuePosition: 1,
            spotifyURI: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA")
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let t1 = Date(timeIntervalSinceReferenceDate: 1_002)
        let livingGroup = GroupID(coordinator: House.living)
        let snap0 = snapshot(
            [speaker(House.living, room: "Living Room")],
            coordinatorOf: alone([House.living]),
            status: [
                livingGroup: GroupStatus(
                    playback: .playing(.track(track), elapsed: .seconds(10), sampledAt: t0),
                    volume: .v25
                ),
            ],
            at: t0
        )
        let snap1 = snapshot(
            [speaker(House.living, room: "Living Room")],
            coordinatorOf: alone([House.living]),
            status: [
                livingGroup: GroupStatus(
                    playback: .playing(.track(track), elapsed: .seconds(12), sampledAt: t1),
                    volume: .v25
                ),
            ],
            at: t1
        )
        #expect(snap0.isSemanticallyEquivalent(to: snap1))

        // A user seek jumping 45 seconds ahead at t1 is NOT semantically equivalent
        let soughtSnap = snapshot(
            [speaker(House.living, room: "Living Room")],
            coordinatorOf: alone([House.living]),
            status: [
                livingGroup: GroupStatus(
                    playback: .playing(.track(track), elapsed: .seconds(55), sampledAt: t1),
                    volume: .v25
                ),
            ],
            at: t1
        )
        #expect(!snap0.isSemanticallyEquivalent(to: soughtSnap))
    }

    @Test func parsesSonosMuseAreasIncludingWoodshopSavedGroup() throws {
        let validSpeakers: Set<SpeakerUUID> = [House.kitchen, House.dining, House.living, House.bedroom]
        let museJSON = """
        [{"namespace":"areas","command":"getAreas","cmdId":"1"},{"areas":[
          {"id":"550E8400-E29B-41D4-A716-446655440000","name":"Woodshop","isReadOnly":false,"playerIds":["\(House.living.rawValue)","\(House.kitchen.rawValue)"]},
          {"id":"550E8400-E29B-41D4-A716-446655440001","name":"ReadOnlySystemArea","isReadOnly":true,"playerIds":["\(House.bedroom.rawValue)"]}
        ]}]
        """
        let pills = try #require(SonosMuseClient.parseAreasMessage(museJSON, validSpeakers: validSpeakers))
        #expect(pills.count == 1)
        #expect(pills[0].name == "Woodshop")
        #expect(pills[0].coordinatorUUID == House.living)
        #expect(pills[0].memberUUIDs == [House.kitchen])
    }
}

struct SconeStateTests {
    @Test func firstLaunchStartsWithNoHardcodedPresetsAndAbsorbsSonosPresets() {
        var seeded = SconeState(loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []))
        #expect(seeded.presets.isEmpty)

        let custom = PresetPill(name: "Movie", coordinatorUUID: House.living, memberUUIDs: [])
        let snapWithPresets = HouseholdSnapshot(
            household: nil,
            observedAt: Date(timeIntervalSinceReferenceDate: 100),
            speakers: [:],
            topology: .empty,
            groupStatus: [:],
            rf: .empty,
            presets: [custom],
            networkName: "Feeling 22"
        )
        seeded.absorb(snapWithPresets)
        #expect(seeded.presets.map(\.name) == ["Movie"])
        #expect(seeded.networkName == "Feeling 22")

        let quarantined = SconeState(loaded: LoadedFiles(
            cache: nil, positions: nil, quarantined: ["floorplan-positions.json.corrupt-10"]))
        #expect(quarantined.alert == .quarantined(fileName: "floorplan-positions.json.corrupt-10"))
        #expect(quarantined.presets.isEmpty)
    }

    @Test func cachedRosterLoadsOfflineAndHidesWhenNoHouseholdAnswers() {
        let lastSeen = Date(timeIntervalSinceReferenceDate: 500)
        let soundbar = soundbarWithRearSatellite(reachability: .offline(lastKnownIP: "192.168.68.92", lastSeenAt: lastSeen))
        var state = SconeState(loaded: LoadedFiles(
            cache: homeCache([soundbar], networkName: "Feeling 22"),
            positions: nil, quarantined: []))
        #expect(state.connection == .searching)
        #expect(state.speakers.map(\.id) == [House.living])
        #expect(state.speakers.flatMap(\.bondedSatellites).map(\.isOnline) == [false])

        state.absorb(HouseholdSnapshot(
            household: nil, observedAt: Date(timeIntervalSinceReferenceDate: 600), speakers: [:], topology: .empty, groupStatus: [:], rf: .empty))
        #expect(state.connection == .away(lastSeenAt: lastSeen))
        #expect(state.speakers.isEmpty)
        #expect(state.floorplan.isEmpty)
        #expect(state.persisted.cache.households[House.household]?.speakers.map(\.id) == [House.living])
    }

    @Test func anotherHouseholdShowsOnlyItsRoomsAndKeepsThisOneForLater() {
        let stale = soundbarWithRearSatellite(
            reachability: .offline(lastKnownIP: "192.168.68.92", lastSeenAt: Date(timeIntervalSinceReferenceDate: 500)))
        var state = SconeState(
            loaded: LoadedFiles(cache: homeCache([stale], networkName: "Feeling 22"), positions: nil, quarantined: []),
            initialPresets: [PresetPill(name: "Movie", coordinatorUUID: House.living, memberUUIDs: [])])

        state.absorb(snapshot(
            [speaker(Office.speaker, room: "315 4th floor", ip: "10.20.0.8")],
            coordinatorOf: alone([Office.speaker]),
            household: Office.household))
        #expect(state.connection == .live)
        #expect(state.speakers.map(\.id) == [Office.speaker])
        #expect(state.floorplan.map(\.id) == [Office.speaker])
        #expect(state.networkName == nil)
        #expect(state.presets.isEmpty)
        #expect(state.persisted.cache.current == Office.household)
        #expect(state.persisted.cache.households[House.household]?.speakers.map(\.id) == [House.living])
        #expect(state.persisted.cache.households[House.household]?.networkName == "Feeling 22")

        state.absorb(snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker", ip: "192.168.68.58")],
            coordinatorOf: alone([House.kitchen]),
            at: Date(timeIntervalSinceReferenceDate: 2_000)))
        #expect(state.speakers.map(\.id) == [House.kitchen, House.living])
        #expect(state.floorplan.map(\.id).sorted() == [House.living, House.kitchen].sorted())
        #expect(state.networkName == "Feeling 22")
        #expect(state.persisted.cache.current == House.household)
        #expect(state.persisted.cache.households[Office.household]?.speakers.map(\.id) == [Office.speaker])
    }

    @Test func launchShowsOnlyTheLastHouseholdsRoster() {
        let office = speaker(Office.speaker, room: "315 4th floor", ip: "10.20.0.8")
            .lastKnown(seenAt: Date(timeIntervalSinceReferenceDate: 400))
        let home = speaker(House.kitchen, room: "Kitchen Speaker", ip: "192.168.68.58")
            .lastKnown(seenAt: Date(timeIntervalSinceReferenceDate: 500))
        let loaded = LoadedFiles(
            cache: CachedSpeakersFile(current: House.household, households: [
                House.household: HouseholdRoster(speakers: [home], rf: .empty),
                Office.household: HouseholdRoster(speakers: [office], rf: .empty),
            ]),
            positions: nil, quarantined: [])
        let state = SconeState(loaded: loaded)
        #expect(state.connection == .searching)
        #expect(state.speakers.map(\.id) == [House.kitchen])
        #expect(loaded.seedIPs == ["192.168.68.58", "10.20.0.8"])
    }

    @Test func liveSatellitesAreSavedOffline() {
        var state = SconeState(loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []))
        let soundbar = soundbarWithRearSatellite(reachability: .online(ip: "192.168.68.92", rssi: -40, noiseFloor: -98))
        state.absorb(HouseholdSnapshot(
            household: House.household, observedAt: Date(timeIntervalSinceReferenceDate: 1_000), speakers: [House.living: soundbar],
            topology: topology(alone([House.living])), groupStatus: [:], rf: .empty))
        #expect(state.speakers.flatMap(\.bondedSatellites).map(\.isOnline) == [true])
        #expect(state.persisted.cache.households[House.household]?.speakers.flatMap(\.bondedSatellites).map(\.isOnline) == [false])
    }

    @Test func renameAndUpdateTrimAndLeaveBlankOrUnknownIdsAlone() {
        let initial = PresetPill(name: "Kitchen + Dining", coordinatorUUID: House.kitchen, memberUUIDs: [House.dining])
        var state = SconeState(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            initialPresets: [initial])
        let id = state.presets[0].id
        state.renamePreset(id, to: "  Downstairs  ")
        #expect(state.presets[0].name == "Downstairs")
        state.renamePreset(id, to: "   ")
        #expect(state.presets[0].name == "Downstairs")
        state.renamePreset(PresetID(), to: "Nope")
        #expect(state.presets.map(\.name) == ["Downstairs"])
    }

    @Test func absorbKeepsUnseenRoomsAndPinsWinOverInference() {
        let old = Date(timeIntervalSinceReferenceDate: 10)
        let basement = Speaker(
            id: House.basement, roomName: "Basement Speaker", model: .move(battery: nil),
            reachability: .offline(lastKnownIP: "192.168.68.95", lastSeenAt: old), volume: .v10)
        let cachedKitchenBefore = Speaker(
            id: House.kitchen, roomName: "Kitchen Speaker", model: .era100,
            reachability: .offline(lastKnownIP: "192.168.68.58", lastSeenAt: old), volume: .v20)
        var state = SconeState(loaded: LoadedFiles(
            cache: homeCache([basement, cachedKitchenBefore]),
            positions: nil,
            quarantined: []))
        let seen = Date(timeIntervalSinceReferenceDate: 80)
        state.absorb(snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker", ip: "192.168.68.58")],
            coordinatorOf: alone([House.kitchen]),
            at: seen))
        #expect(state.floorplan.map(\.speaker.roomName) == ["Basement Speaker", "Kitchen Speaker"])
        #expect(state.floorplan[0].speaker.reachability == .offline(lastKnownIP: "192.168.68.95", lastSeenAt: old))
        #expect(state.floorplan[0].group == nil)
        #expect(state.floorplan[0].level == .lower)
        #expect(state.floorplan[0].coordinate == RoomCoordinate(clampingX: 0.50, y: 0.81))
        #expect(state.floorplan[1].level == .upper)
        #expect(state.floorplan[1].coordinate == RoomCoordinate(clampingX: 0.50, y: 0.37))
        #expect(state.floorplan[1].placement == .inferred)
        #expect(state.floorplan[1].group == GroupID(coordinator: House.kitchen))
        #expect(state.floorplan[1].speaker.reachability.isOnline)
        let cachedKitchen = state.persisted.cache.households[House.household]?.speakers.first { $0.id == House.kitchen }
        #expect(cachedKitchen?.reachability == .offline(lastKnownIP: "192.168.68.58", lastSeenAt: seen))

        let pin = RoomCoordinate(clampingX: 0.10, y: 0.90)
        state.pin(House.kitchen, at: pin)
        #expect(state.floorplan[1].coordinate == pin)
        #expect(state.floorplan[1].placement == .pinned)
    }

    @Test func playPauseProjectsTheDesiredTransportAndDropsItWhenTheCommandFinishes() {
        let song = NowPlaying.track(NowPlayingTrack(
            title: "Song", artist: "Artist", album: nil, artworkURL: nil,
            duration: .seconds(180), queuePosition: 2, spotifyURI: nil))
        let observed = Date(timeIntervalSinceReferenceDate: 1_000)
        let paused = PlaybackState.paused(song, elapsed: .seconds(12))
        let group = GroupID(coordinator: House.kitchen)
        var state = SconeState(loaded: LoadedFiles(
            cache: nil, positions: nil, quarantined: []))
        state.absorb(snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker")],
            coordinatorOf: alone([House.kitchen]),
            status: [group: GroupStatus(playback: paused, volume: .v30)],
            at: observed))
        let ticket = state.begin(.playPause(.play, group: group))
        #expect(state.groups.map(\.playback) == [.playing(song, elapsed: .seconds(12), sampledAt: observed)])
        state.finish(ticket, with: .success(.applied))
        #expect(state.groups.map(\.playback) == [paused])

        let started = observed.addingTimeInterval(-5)
        state.absorb(snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker")],
            coordinatorOf: alone([House.kitchen]),
            status: [group: GroupStatus(
                playback: .playing(song, elapsed: .seconds(12), sampledAt: started), volume: .v30)],
            at: observed))
        _ = state.begin(.playPause(.pause, group: group))
        #expect(state.groups.map(\.playback) == [.paused(song, elapsed: .seconds(12))])

        state.absorb(snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker")],
            coordinatorOf: alone([House.kitchen]),
            at: observed))
        _ = state.begin(.playPause(.play, group: group))
        #expect(state.groups.map(\.playback) == [.stopped])
    }

    @Test func groupingOutcomeRecordsOnlyFinishedRegroupsThisAppSent() {
        var state = SconeState(loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []))
        let kitchen = GroupID(coordinator: House.kitchen)
        func finish(_ command: SonosCommand, _ result: Result<CommandOutcome, SonosCommandError>) -> GroupingOutcome? {
            let ticket = state.begin(command)
            state.finish(ticket, with: result)
            return state.lastGroupingOutcome
        }

        let joined = finish(.group(member: House.dining, intoCoordinator: kitchen), .success(.applied))
        #expect(joined?.kind == .grouped)
        let joinedAgain = finish(.group(member: House.living, intoCoordinator: kitchen), .success(.applied))
        #expect(joinedAgain?.kind == .grouped)
        #expect(joinedAgain != joined)

        let left = finish(.ungroup(member: House.dining), .success(.applied))
        #expect(left?.kind == .ungrouped)
        let dissolve = PresetPill(name: "Kitchen", coordinatorUUID: House.kitchen, memberUUIDs: [])
        let dissolved = finish(.applyPreset(dissolve), .success(.applied))
        #expect(dissolved?.kind == .ungrouped)
        let everywhere = PresetPill(name: "Everywhere", coordinatorUUID: House.kitchen, memberUUIDs: [House.dining])
        let regrouped = finish(.applyPreset(everywhere), .success(.applied))
        #expect(regrouped?.kind == .grouped)

        let unchanged = finish(.ungroup(member: House.bedroom), .success(.alreadySatisfied))
        #expect(unchanged == regrouped)
        let transport = finish(.playPause(.play, group: kitchen), .failure(.speakerUnreachable(House.kitchen)))
        #expect(transport == regrouped)

        let timedOut = finish(.ungroup(member: House.dining), .failure(.notConverged(after: .seconds(8))))
        #expect(timedOut?.kind == .failed)
        let partial = finish(.applyPreset(everywhere), .success(.partiallyApplied(unreachable: [House.dining])))
        #expect(partial?.kind == .failed)
    }

    @Test func optimisticVolumeSuppressesIncomingPollUpdatesUntilWindowExpires() {
        var state = SconeState(loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []))
        let initialTime = Date()
        state.absorb(snapshot(
            [
                speaker(House.kitchen, room: "Kitchen Speaker", volume: .v15),
                speaker(House.dining, room: "Dining Room Speaker", volume: .v25),
            ],
            coordinatorOf: [House.kitchen: House.kitchen, House.dining: House.kitchen],
            at: initialTime))

        state.setOptimisticVolume(.v40, for: .speaker(House.kitchen), now: initialTime)
        #expect(state.speakers.first { $0.id == House.kitchen }?.volume == .v40)

        state.setOptimisticVolume(.v35, for: .group(GroupID(coordinator: House.kitchen)), now: initialTime)
        #expect(state.groups.first?.volume == .v35)

        // Incoming stale poll 300ms later still reporting .v15 should be suppressed by optimistic window
        state.absorb(snapshot(
            [
                speaker(House.kitchen, room: "Kitchen Speaker", volume: .v15),
                speaker(House.dining, room: "Dining Room Speaker", volume: .v25),
            ],
            coordinatorOf: [House.kitchen: House.kitchen, House.dining: House.kitchen],
            at: initialTime.addingTimeInterval(0.3)))
        #expect(state.speakers.first { $0.id == House.kitchen }?.volume == .v40)

        // Poll after 1.5s expiration window reflects the speaker's actual state
        let afterWindow = initialTime.addingTimeInterval(1.5)
        state.absorb(snapshot(
            [
                speaker(House.kitchen, room: "Kitchen Speaker", volume: .v38),
                speaker(House.dining, room: "Dining Room Speaker", volume: .v25),
            ],
            coordinatorOf: [House.kitchen: House.kitchen, House.dining: House.kitchen],
            at: afterWindow))
        #expect(state.speakers.first { $0.id == House.kitchen }?.volume == .v38)
    }

    @Test func clippedCurveSegmentTerminatesCleanlyAtNodeBoundaries() {
        let hubCenter = CGPoint(x: 200, y: 200)
        let roomCenter = CGPoint(x: 500, y: 200)
        let baseSegment = AcousticCurveSegment(
            start: hubCenter,
            control: CGPoint(x: 350, y: 200),
            end: roomCenter
        )
        let clipped = AcousticCurveRouter.clippedSegment(
            baseSegment,
            startRect: CGRect(x: 200 - 96, y: 200 - 40, width: 192, height: 80),
            endRect: CGRect(x: 500 - 50, y: 200 - 50, width: 100, height: 100),
            inset: 0
        )
        #expect(abs(clipped.start.x - 296) <= 3.0)
        #expect(abs(clipped.end.x - 450) <= 3.0)
    }
}

struct SconeFileTests {
    @Test func saveRoundTripsAndQuarantinesCorruptUserFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "nested/house")
        let files = SconeFiles(directory: nested)
        let pin = RoomCoordinate(clampingX: 0.25, y: 0.75)
        try files.save(FloorplanPositionsFile(pins: [House.living: pin]), to: .floorplanPositions)
        guard case .loaded(let loaded) = files.load(FileSlot.floorplanPositions) else {
            Issue.record("expected floorplan positions to load")
            return
        }
        #expect(loaded.pins == [House.living: pin])

        let allMissing = SconeFiles(directory: directory.appending(path: "absent")).loadAll()
        #expect(allMissing.cache == nil)
        #expect(allMissing.positions == nil)
        #expect(allMissing.quarantined == [])

        try Data("not json".utf8).write(to: nested.appending(path: "floorplan-positions.json"))
        try Data("not json".utf8).write(to: nested.appending(path: "cached-speakers.json"))
        let recovered = files.loadAll()
        #expect(recovered.positions == nil)
        #expect(recovered.cache == nil)
        #expect(recovered.quarantined.count == 1)
        let quarantined = try #require(recovered.quarantined.first)
        #expect(quarantined.hasPrefix("floorplan-positions.json.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: nested.appending(path: quarantined).path))
        #expect(!FileManager.default.fileExists(atPath: nested.appending(path: "floorplan-positions.json").path))
        #expect(!FileManager.default.fileExists(atPath: nested.appending(path: "cached-speakers.json").path))
    }

    @Test @MainActor func userEditsWriteImmediatelyAndTheCacheWaitsThirtySeconds() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let seededPreset = PresetPill(name: "Kitchen + Dining", coordinatorUUID: House.kitchen, memberUUIDs: [House.dining])
        let recorder = RecordingSonos(yielded: [])
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: recorder,
            spotify: IdleSpotify(),
            initialPresets: [seededPreset])
        let id = store.state.presets[0].id
        store.renamePreset(id, to: "Downstairs")
        for _ in 0..<10 where recorder.commands.isEmpty { await Task.yield() }
        #expect(store.state.presets.map(\.name) == ["Downstairs"])
        if case .savePresets(let saved) = recorder.commands.last {
            #expect(saved.map(\.name) == ["Downstairs"])
        } else {
            Issue.record("expected .savePresets command to be sent to Sonos")
        }

        let pin = RoomCoordinate(clampingX: 0.12, y: 0.88)
        store.moveRoom(House.kitchen, to: pin)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while case .missing = files.load(FileSlot.floorplanPositions), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .loaded(let positions) = files.load(FileSlot.floorplanPositions) else {
            Issue.record("expected floorplan-positions.json")
            return
        }
        #expect(positions.pins[House.kitchen] == pin)

        let firstDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let secondDate = Date(timeIntervalSinceReferenceDate: 1_005)
        let first = snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker", volume: .v20)],
            coordinatorOf: alone([House.kitchen]),
            at: firstDate)
        var matrix = RFPeerMatrix.empty
        matrix.record(House.bedroom, House.guest, from: 42, to: 43)
        let second = snapshot(
            [speaker(House.kitchen, room: "Kitchen Speaker", volume: .v40)],
            coordinatorOf: alone([House.kitchen]),
            rf: matrix,
            at: secondDate)
        let sweeping = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: ScriptedSonos(yielded: [first, second]),
            spotify: IdleSpotify())
        await sweeping.run()
        guard case .loaded(let cache) = files.load(FileSlot.cachedSpeakers) else {
            Issue.record("expected cached-speakers.json")
            return
        }
        let home = try #require(cache.households[House.household])
        #expect(cache.current == House.household)
        #expect(home.speakers.first?.volume == .v20)
        #expect(home.speakers.first?.reachability == .offline(lastKnownIP: "192.168.68.58", lastSeenAt: firstDate))
        #expect(home.rf.band(House.bedroom, House.guest) == nil)
        let persisted = try #require(sweeping.state.persisted.cache.households[House.household])
        #expect(persisted.speakers.first?.volume == .v40)
        #expect(persisted.rf.band(House.bedroom, House.guest) == .strong)
    }

    @Test func discoverySeedsDeduplicateCachedAddressesWithoutHardcodedFallbacks() {
        #expect(SconeStore.mergedSeedIPs(cached: []).isEmpty)
        #expect(SconeStore.mergedSeedIPs(cached: ["10.0.0.8", "10.0.0.12", "10.0.0.8"]) == [
            "10.0.0.8", "10.0.0.12",
        ])
    }

    @Test @MainActor func draggingAnySpeakerOntoAnyOtherSpeakerOrSeveringUnitesAndDissolvesCleanly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let initial = snapshot(
            [
                speaker(House.kitchen, room: "Kitchen Speaker"),
                speaker(House.dining, room: "Dining Room Speaker"),
                speaker(House.bedroom, room: "Bedroom Speaker"),
                speaker(House.living, room: "Living Room Soundbar"),
            ],
            coordinatorOf: [
                House.kitchen: House.kitchen,
                House.dining: House.kitchen,
                House.bedroom: House.bedroom,
                House.living: House.living,
            ])
        let recorder = RecordingSonos(yielded: [initial])
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: recorder,
            spotify: IdleSpotify())
        await store.run()

        // 1. Drag grouped coordinator (Kitchen) onto standalone speaker (Bedroom):
        // Should unite Kitchen + Dining + Bedroom instead of breaking Dining away from Kitchen!
        store.group(member: House.kitchen, onto: House.bedroom)
        for _ in 0..<10 where recorder.commands.isEmpty { await Task.yield() }
        let firstCmd = try #require(recorder.commands.last)
        if case .group(let member, let coordinator) = firstCmd {
            #expect(member == House.bedroom)
            #expect(coordinator == GroupID(coordinator: House.kitchen))
        } else {
            Issue.record("expected .group(Bedroom, Kitchen), got \(firstCmd)")
        }

        // 2. Disconnect coordinator (Kitchen) from a 2-speaker group:
        // Sends .ungroup(House.kitchen) which delegates coordination to Dining so Dining keeps playing!
        store.ungroupSpeaker(House.kitchen)
        for _ in 0..<10 where recorder.commands.count < 2 { await Task.yield() }
        let ungroupCmd = try #require(recorder.commands.last)
        if case .ungroup(let member) = ungroupCmd {
            #expect(member == House.kitchen)
        } else {
            Issue.record("expected .ungroup(Kitchen), got \(ungroupCmd)")
        }
    }

    @Test @MainActor func groupingPausedRoomWithIdleRoomPromotesPausedRoomAsCoordinator() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let pausedSong = NowPlaying.track(NowPlayingTrack(
            title: "Creep",
            artist: "Radiohead",
            album: "Pablo Honey",
            artworkURL: nil,
            duration: .seconds(238),
            queuePosition: 1,
            spotifyURI: SpotifyURI("spotify:track:70LcF31zb1H0PyJoS1Sx1r")
        ))
        let guestGroupID = GroupID(coordinator: House.guest)
        let bedroomGroupID = GroupID(coordinator: House.bedroom)
        let initial = snapshot(
            [
                speaker(House.bedroom, room: "Bedroom Speaker"),
                speaker(House.guest, room: "Guest Room Speaker"),
            ],
            coordinatorOf: [
                House.bedroom: House.bedroom,
                House.guest: House.guest,
            ],
            status: [
                bedroomGroupID: GroupStatus(playback: .stopped, volume: .v15),
                guestGroupID: GroupStatus(playback: .paused(pausedSong, elapsed: .seconds(42)), volume: .v25),
            ]
        )
        let preset = PresetPill(
            name: "Bedroom + Guest",
            coordinatorUUID: House.bedroom,
            memberUUIDs: [House.guest]
        )
        let recorder = RecordingSonos(yielded: [initial])
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: recorder,
            spotify: IdleSpotify(),
            initialPresets: [preset]
        )
        await store.run()

        // Dragging paused Guest Room onto idle Bedroom must make Guest Room the coordinator
        store.group(member: House.guest, onto: House.bedroom)
        for _ in 0..<10 where recorder.commands.isEmpty { await Task.yield() }
        let groupCmd = try #require(recorder.commands.last)
        if case .group(let member, let coordinator) = groupCmd {
            #expect(member == House.bedroom)
            #expect(coordinator == guestGroupID)
        } else {
            Issue.record("expected .group(Bedroom, intoCoordinator: Guest), got \(groupCmd)")
        }

        // Applying a preset whose saved coordinator (Bedroom) is idle while member (Guest) is paused
        // promotes Guest to coordinator so playback is preserved
        store.applyPreset(preset)
        for _ in 0..<10 where recorder.commands.count < 2 { await Task.yield() }
        let presetCmd = try #require(recorder.commands.last)
        if case .applyPreset(let appliedPill) = presetCmd {
            #expect(appliedPill.coordinatorUUID == House.guest)
            #expect(appliedPill.memberUUIDs == [House.bedroom])
        } else {
            Issue.record("expected .applyPreset with Guest as coordinator, got \(presetCmd)")
        }

        // Preset pill should report active even when Guest is coordinator and Bedroom is member
        var groupedState = store.state
        groupedState.absorb(snapshot(
            [
                speaker(House.bedroom, room: "Bedroom Speaker"),
                speaker(House.guest, room: "Guest Room Speaker"),
            ],
            coordinatorOf: [
                House.bedroom: House.guest,
                House.guest: House.guest,
            ],
            status: [
                guestGroupID: GroupStatus(playback: .paused(pausedSong, elapsed: .seconds(42)), volume: .v25),
            ]
        ))
        #expect(groupedState.isActive(preset))
    }

    @Test @MainActor func storeEnrichesSingleActiveGroupAndThrottlesSpotifyPollingOnNothingPlaying() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)

        let rawTrack = NowPlayingTrack(
            title: "Notorious",
            artist: "Collect 200",
            album: "Collect 200",
            artworkURL: nil,
            duration: .seconds(210),
            queuePosition: 1,
            spotifyURI: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA"),
            source: .spotify(contextTitle: nil),
            upNext: [QueueItem(title: "Test My Luck", artist: "Purple Disco Machine")]
        )
        let livingGroup = GroupID(coordinator: House.living)
        let bedroomGroup = GroupID(coordinator: House.bedroom)
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000)
        let t1 = Date(timeIntervalSinceReferenceDate: 2_002)
        let t2 = Date(timeIntervalSinceReferenceDate: 2_004)

        let makePoll = { (time: Date, elapsedSec: Int) -> HouseholdSnapshot in
            HouseholdSnapshot(
                household: House.household,
                observedAt: time,
                speakers: Dictionary(uniqueKeysWithValues: [
                    speaker(House.living, room: "Living Room"),
                    speaker(House.bedroom, room: "Bedroom"),
                ].map { ($0.id, $0) }),
                topology: topology([
                    House.living: House.living,
                    House.bedroom: House.bedroom,
                ]),
                groupStatus: [
                    livingGroup: GroupStatus(
                        playback: .playing(.track(rawTrack), elapsed: .seconds(elapsedSec), sampledAt: time),
                        volume: .v30
                    ),
                    bedroomGroup: GroupStatus(
                        playback: .paused(.track(rawTrack), elapsed: .seconds(15)),
                        volume: .v20
                    ),
                ],
                rf: .empty
            )
        }

        let countingSpotify = CountingSpotify(
            response: .success(
                SpotifyTrackContext(
                    uri: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA")!,
                    metadata: SpotifyTrackMetadata(
                        title: "Notorious",
                        artist: "Collect 200",
                        album: "Collect 200",
                        artworkURL: URL(string: "https://i.scdn.co/image/notorious"),
                        duration: .seconds(210)
                    ),
                    position: .seconds(48),
                    contextTitle: "Playlist \"Collect\"",
                    contextURI: "spotify:playlist:123",
                    deviceName: "Living Room",
                    isShuffling: true,
                    upNext: [
                        QueueItem(
                            id: "1",
                            title: "Next Track",
                            artist: "Collect 200",
                            spotifyURI: SpotifyURI("spotify:track:0FlfN5cbUUpIHCRH8X1M44")
                        ),
                    ]
                )
            )
        )

        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: ScriptedSonos(yielded: [makePoll(t0, 48), makePoll(t1, 50), makePoll(t2, 52)]),
            spotify: countingSpotify
        )
        await store.run()

        // 1. Spotify context was fetched only ONCE across the 3 polls within the 30s window
        #expect(countingSpotify.callCount == 1)

        // 2. Living Room is .playing with enriched Spotify context & upNext queue,
        // while Bedroom's duplicate .paused session is cleared to .stopped!
        let groupsByID = Dictionary(uniqueKeysWithValues: store.state.groups.map { ($0.id, $0) })
        let livingPlayback = try #require(groupsByID[livingGroup]?.playback)
        let bedroomPlayback = try #require(groupsByID[bedroomGroup]?.playback)
        #expect(bedroomPlayback == .stopped)
        guard case .playing(.track(let enrichedLiving), _, _) = livingPlayback else {
            Issue.record("expected Living Room to be playing, got \(livingPlayback)")
            return
        }
        #expect(enrichedLiving.source == .spotify(contextTitle: "Playlist \"Collect\""))
        #expect(enrichedLiving.upNext.map(\.title) == ["Next Track"])

        // 3. Even when Spotify throws .nothingPlaying, SconeStore respects the 30s TTL
        // and does NOT hammer Spotify on every 2s poll tick.
        let idleCountingSpotify = CountingSpotify(response: .failure(.nothingPlaying))
        let storeWithIdleSpotify = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: ScriptedSonos(yielded: [makePoll(t0, 48), makePoll(t1, 50), makePoll(t2, 52)]),
            spotify: idleCountingSpotify
        )
        await storeWithIdleSpotify.run()
        #expect(idleCountingSpotify.callCount == 1)

        // 4. Rapid 1% slider steps coalesce into at most 2 SOAP SetVolume calls
        let volumeRecorder = RecordingSonos(yielded: [makePoll(t0, 48)])
        let volumeStore = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: volumeRecorder,
            spotify: IdleSpotify()
        )
        await volumeStore.run()
        let target = VolumeTarget.speaker(House.living)
        for pct in 21...45 {
            volumeStore.setVolume(DiscreteVolume(snappingPercent: pct), for: target)
        }
        #expect(volumeStore.state.speakers.first { $0.id == House.living }?.volume == .v45)
        try? await Task.sleep(for: .milliseconds(160))
        let setVolCommands = volumeRecorder.commands.compactMap { cmd -> DiscreteVolume? in
            if case .setVolume(let vol, _) = cmd { return vol }
            return nil
        }
        #expect(setVolCommands.count == 1)
        #expect(setVolCommands.last == .v45)
    }


    @Test @MainActor func setShuffleAsksSpotifyThenRefetchesItsState() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spotify = CountingSpotify(response: .failure(.nothingPlaying))
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: SconeFiles(directory: directory),
            sonos: ScriptedSonos(yielded: []),
            spotify: spotify
        )

        store.setShuffle(false)
        for _ in 0..<50 where spotify.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(spotify.shuffleRequests == [false])
        #expect(spotify.callCount == 1)
    }

    @Test @MainActor func playOnPausedSpotifyConnectRoomResumesOverUPnPWithoutEnqueueing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectTrack = NowPlayingTrack(
            title: "Disparate Youth",
            artist: "Santigold",
            album: nil,
            artworkURL: nil,
            duration: .seconds(245),
            queuePosition: nil,
            spotifyURI: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA"),
            isSpotifyConnect: true
        )
        let livingGroup = GroupID(coordinator: House.living)
        let sonos = RecordingSonos(yielded: [snapshot(
            [speaker(House.living, room: "Living Room")],
            coordinatorOf: [House.living: House.living],
            status: [livingGroup: GroupStatus(playback: .paused(.track(connectTrack), elapsed: .seconds(30)), volume: .v25)]
        )])
        let spotify = CountingSpotify(response: .failure(.nothingPlaying))
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: SconeFiles(directory: directory),
            sonos: sonos,
            spotify: spotify
        )
        await store.run()
        let callsBeforePlay = spotify.callCount

        let group = try #require(store.state.groups.first { $0.id == livingGroup })
        store.togglePlayOrHandOffSpotify(for: group)
        for _ in 0..<50 where sonos.commands.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(sonos.commands == [.playPause(.play, group: livingGroup)])
        #expect(spotify.transferredRooms.isEmpty)
        #expect(spotify.callCount == callsBeforePlay)
    }

    @Test @MainActor func upNextTapOnSpotifyConnectRoomSkipsForwardInsteadOfEnqueueing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trackURI = SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA")!
        let connectTrack = NowPlayingTrack(
            title: "Crown",
            artist: "Stormzy",
            album: nil,
            artworkURL: nil,
            duration: .seconds(240),
            queuePosition: nil,
            spotifyURI: trackURI,
            isSpotifyConnect: true
        )
        let upNext = ["Days Like This", "Karma Tax", "Helpless"].enumerated().map { index, title in
            QueueItem(id: "\(index)", title: title, artist: nil, spotifyURI: SpotifyURI("spotify:track:0FlfN5cbUUpIHCRH8X1M4\(index)"))
        }
        let livingGroup = GroupID(coordinator: House.living)
        let sonos = RecordingSonos(yielded: [snapshot(
            [speaker(House.living, room: "Living Room")],
            coordinatorOf: [House.living: House.living],
            status: [livingGroup: GroupStatus(
                playback: .playing(.track(connectTrack), elapsed: .seconds(30), sampledAt: Date()),
                volume: .v25
            )]
        )])
        let spotify = CountingSpotify(response: .success(SpotifyTrackContext(
            uri: trackURI,
            metadata: SpotifyTrackMetadata(title: "Crown", artist: "Stormzy", album: nil, artworkURL: nil, duration: .seconds(240)),
            position: .seconds(30),
            deviceName: "Living Room",
            isPlaying: true,
            upNext: upNext
        )))
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: SconeFiles(directory: directory),
            sonos: sonos,
            spotify: spotify
        )
        await store.run()
        guard case .track(let enriched) = store.state.groups.first(where: { $0.id == livingGroup })?.playback.nowPlaying else {
            Issue.record("expected the Living Room track")
            return
        }
        #expect(enriched.upNext == upNext)

        store.playQueueItem(upNext[2], on: livingGroup)
        for _ in 0..<50 where sonos.commands.count < 4 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(sonos.commands == [
            .nextTrack(group: livingGroup),
            .nextTrack(group: livingGroup),
            .nextTrack(group: livingGroup),
            .playPause(.play, group: livingGroup),
        ])
    }

    @Test @MainActor func playOnDormantSpotifyConnectRoomRevivesItWithoutEnqueueing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let guestGroup = GroupID(coordinator: House.living)
        let sonos = RecordingSonos(
            yielded: [snapshot(
                [speaker(House.living, room: "Guest Room Speaker")],
                coordinatorOf: [House.living: House.living],
                status: [guestGroup: GroupStatus(playback: .stopped, volume: .v25)]
            )],
            spotifyConnectGroups: [guestGroup]
        )
        let spotify = CountingSpotify(response: .failure(.nothingPlaying))
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: SconeFiles(directory: directory),
            sonos: sonos,
            spotify: spotify
        )
        await store.run()
        let callsBeforePlay = spotify.callCount

        let group = try #require(store.state.groups.first { $0.id == guestGroup })
        store.togglePlayOrHandOffSpotify(for: group)
        for _ in 0..<50 where sonos.commands.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(sonos.commands == [.resumeSpotifyConnect(group: guestGroup)])
        #expect(spotify.transferredRooms.isEmpty)
        #expect(spotify.callCount == callsBeforePlay)
        #expect(store.state.alert == nil)
    }

    @Test func spotifyPlayerStateCarriesShuffleState() throws {
        let data = Data("""
        {"is_playing": true, "shuffle_state": true, "progress_ms": 1000,
         "item": {"type": "track", "uri": "spotify:track:2mqTtvbKxH7SoEQ2oGAnsA", "name": "Disparate Youth",
                  "artists": [{"name": "Santigold"}], "album": {"name": "Master of My Make-Believe"}}}
        """.utf8)
        let context = try #require(try WebAPI.parseCurrentlyPlaying(data))
        #expect(context.isShuffling == true)
    }
    @Test @MainActor func spotifyDeviceMatcherAndPlayHandOffAndCoordinatorPreservation() async throws {
        // 1. SpotifyDeviceMatcher normalizes "+ N" group suffixes and room speaker suffixes
        #expect(SpotifyDeviceMatcher.matches(deviceName: "Bedroom Speaker + 4", roomName: "Bedroom Speaker"))
        #expect(SpotifyDeviceMatcher.matches(deviceName: "Bedroom Speaker + 4", roomName: "Bedroom"))
        #expect(SpotifyDeviceMatcher.matches(deviceName: "Dining Room Speaker", roomName: "Dining Room Speaker"))
        #expect(!SpotifyDeviceMatcher.matches(deviceName: "Bedroom Speaker + 4", roomName: "Kitchen Speaker"))

        // 2. Drag hit-testing resolves nearest stationary speaker or music hub within dropRadius
        let stationaryPositions: [SpeakerUUID: CGPoint] = [
            House.kitchen: CGPoint(x: 180, y: 160),
            House.dining: CGPoint(x: 340, y: 160),
            House.bedroom: CGPoint(x: 500, y: 160),
        ]
        let hubs: [GroupID: CGPoint] = [
            GroupID(coordinator: House.bedroom): CGPoint(x: 500, y: 95),
        ]
        let hitSpeaker = FloorplanDragHitTesting.nearestTarget(
            to: CGPoint(x: 352, y: 168),
            excluding: House.kitchen,
            draggedGroup: GroupID(coordinator: House.kitchen),
            displayPoints: stationaryPositions,
            hubLocations: hubs,
            dropRadius: 78
        )
        #expect(hitSpeaker == .speaker(House.dining))

        let hitHub = FloorplanDragHitTesting.nearestTarget(
            to: CGPoint(x: 495, y: 102),
            excluding: House.kitchen,
            draggedGroup: GroupID(coordinator: House.kitchen),
            displayPoints: stationaryPositions,
            hubLocations: hubs,
            dropRadius: 78
        )
        #expect(hitHub == .musicHub(GroupID(coordinator: House.bedroom)))

        let missFar = FloorplanDragHitTesting.nearestTarget(
            to: CGPoint(x: 50, y: 400),
            excluding: House.kitchen,
            draggedGroup: GroupID(coordinator: House.kitchen),
            displayPoints: stationaryPositions,
            hubLocations: hubs,
            dropRadius: 78
        )
        #expect(missFar == nil)

        // 3. Pressing Play on a paused Spotify stream wakes/resumes Spotify instead of raw UPnP Play,
        // and grouping Everywhere preserves the active Spotify Connect coordinator ("Bedroom Speaker + 4").
        let trackURI = SpotifyURI("spotify:track:4iV5W9uYEdYUVa79Axb7Rh")!
        let pausedSpotifyTrack = NowPlayingTrack(
            title: "Show Me Love",
            artist: "WizTheMc, bees & honey",
            album: "Show Me Love",
            artworkURL: nil,
            duration: .seconds(175),
            queuePosition: 1,
            spotifyURI: trackURI,
            source: .spotify(contextTitle: nil)
        )
        let bedroom = speaker(House.bedroom, room: "Bedroom Speaker", ip: "192.168.68.64", volume: .v25)
        let dining = speaker(House.dining, room: "Dining Room Speaker", ip: "192.168.68.58", volume: .v25)
        let kitchen = speaker(House.kitchen, room: "Kitchen Speaker", ip: "192.168.68.61", volume: .v25)
        let snap = snapshot(
            [bedroom, dining, kitchen],
            coordinatorOf: [
                House.bedroom: House.bedroom,
                House.dining: House.bedroom,
                House.kitchen: House.kitchen,
            ],
            status: [
                GroupID(coordinator: House.bedroom): GroupStatus(
                    playback: .paused(.track(pausedSpotifyTrack), elapsed: .seconds(8)),
                    volume: .v25
                ),
                GroupID(coordinator: House.kitchen): GroupStatus(
                    playback: .paused(.track(pausedSpotifyTrack), elapsed: .seconds(8)),
                    volume: .v25
                ),
            ]
        )
        let spotifyCtx = SpotifyTrackContext(
            uri: trackURI,
            metadata: SpotifyTrackMetadata(
                title: "Show Me Love",
                artist: "WizTheMc, bees & honey",
                album: "Show Me Love",
                artworkURL: nil,
                duration: .seconds(175)
            ),
            position: .seconds(8),
            contextTitle: "Playlist \"Liked Songs\"",
            contextURI: "spotify:collection:tracks",
            deviceName: "Bedroom Speaker + 4",
            isPlaying: false,
            upNext: [
                QueueItem(
                    id: "2",
                    title: "Next Song",
                    artist: "Artist 2",
                    spotifyURI: SpotifyURI("spotify:track:1301WleyT98MSxVHPZCA6M")
                ),
            ]
        )
        let sonosRecorder = RecordingSonos(yielded: [snap])
        let spotifyMock = CountingSpotify(response: .success(spotifyCtx))
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: sonosRecorder,
            spotify: spotifyMock
        )
        await store.run()

        // Group Everywhere should pick Bedroom (matching "Bedroom Speaker + 4") as coordinator
        store.groupEverywhere()
        try? await Task.sleep(for: .milliseconds(50))
        let appliedPreset = sonosRecorder.commands.compactMap { cmd -> PresetPill? in
            if case .applyPreset(let p) = cmd { return p }
            return nil
        }.last
        #expect(appliedPreset?.coordinatorUUID == House.bedroom)

        // Pressing Play on paused Spotify stream invokes Spotify / enqueueAndPlaySpotify with upNext
        if let bedroomGroup = store.state.groups.first(where: { $0.id == GroupID(coordinator: House.bedroom) }) {
            store.togglePlayOrHandOffSpotify(for: bedroomGroup)
            try? await Task.sleep(for: .milliseconds(80))
            let enqueuedCmd = sonosRecorder.commands.contains { cmd in
                if case .enqueueAndPlaySpotify(let uri, _, let coord, _, _, let upNext) = cmd {
                    return uri == trackURI && coord == GroupID(coordinator: House.bedroom) && upNext.count == 1
                }
                return false
            }
            #expect(enqueuedCmd)
        }
    }

    @Test func sonosMuseClientCodableParsingAndEncodingAndAsyncPersistence() async throws {
        let infoData = Data(#"{"householdId":"Sonos_Household_12345","device":{"name":"Living Room"}}"#.utf8)
        #expect(SonosMuseClient.parsePlayerHouseholdID(infoData) == "Sonos_Household_12345")
        #expect(SonosMuseClient.parsePlayerHouseholdID(Data(#"{"householdId":"   "}"#.utf8)) == nil)

        let commandJSON = try #require(SonosMuseClient.encodeGetAreasCommand(householdId: "Sonos_Household_12345"))
        #expect(commandJSON.contains(#""namespace":"areas""#))
        #expect(commandJSON.contains(#""command":"getAreas""#))
        #expect(commandJSON.contains(#""householdId":"Sonos_Household_12345""#))

        let presetUUID = UUID()
        let areasPayload = """
        [
          {"namespace":"areas","name":"areasResult"},
          {
            "areas": [
              {
                "id": "\(presetUUID.uuidString)",
                "name": "Upstairs",
                "isReadOnly": false,
                "playerIds": ["\(House.kitchen.rawValue)", "\(House.dining.rawValue)", "\(House.living.rawValue)"]
              },
              {
                "id": "read-only-area",
                "name": "Everywhere",
                "isReadOnly": true,
                "playerIds": ["\(House.kitchen.rawValue)"]
              }
            ]
          }
        ]
        """
        let parsedPills = try #require(
            SonosMuseClient.parseAreasMessage(
                areasPayload,
                validSpeakers: [House.kitchen, House.dining]
            )
        )
        #expect(parsedPills.count == 1)
        #expect(parsedPills[0].id == PresetID(rawValue: presetUUID))
        #expect(parsedPills[0].name == "Upstairs")
        #expect(parsedPills[0].coordinatorUUID == House.kitchen)
        #expect(parsedPills[0].memberUUIDs == [House.dining])

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let pin = RoomCoordinate(clampingX: 0.42, y: 0.64)
        try await files.saveAsync(FloorplanPositionsFile(pins: [House.living: pin]), to: .floorplanPositions)
        guard case .loaded(let loadedPositions) = files.load(FileSlot.floorplanPositions) else {
            Issue.record("expected async-saved floorplan-positions.json")
            return
        }
        #expect(loadedPositions.pins[House.living] == pin)

        let vault = TokenVault(service: "Sconeos.UnitTest", directory: directory)
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        vault.storeAsync(
            accessToken: "access-123",
            expiry: expiry,
            refreshToken: "refresh-456"
        )
        vault.storeDisplayNameAsync("Dylan")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vault.accessToken()?.token == "access-123")
        #expect(vault.accessToken()?.expiry == expiry)
        #expect(vault.refreshToken() == "refresh-456")
        #expect(vault.displayName() == "Dylan")
        vault.clearAsync()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vault.accessToken() == nil)
        #expect(vault.refreshToken() == nil)
        #expect(vault.displayName() == nil)
    }

    @Test @MainActor func dormantSpotifyConnectVLIAndExternalComputerPlaybackTransferToGroup() async throws {
        // 1. Dormant x-sonos-vli container in PAUSED_PLAYBACK with TrackMetaData = NOT_IMPLEMENTED
        // parses as .stopped instead of a hollow .paused track with empty title.
        let endpoint = URL(string: "http://192.168.68.73:1400/xml/device_description.xml")!
        let vliURI = "x-sonos-vli:RINCON_542A1B5F088401400:2,spotify:5a215012d5e6e8eea3c522adc26c27ea"
        let dormantTransport = try XMLNode.parse(Data("""
        <GetTransportInfoResponse>
          <CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>
          <CurrentTransportStatus>OK</CurrentTransportStatus>
          <CurrentSpeed>1</CurrentSpeed>
        </GetTransportInfoResponse>
        """.utf8))
        let dormantPosition = try XMLNode.parse(Data("""
        <GetPositionInfoResponse>
          <Track>1</Track>
          <TrackDuration>NOT_IMPLEMENTED</TrackDuration>
          <TrackMetaData>NOT_IMPLEMENTED</TrackMetaData>
          <TrackURI>\(vliURI)</TrackURI>
          <RelTime>NOT_IMPLEMENTED</RelTime>
        </GetPositionInfoResponse>
        """.utf8))
        let dormantMedia = try XMLNode.parse(Data("""
        <GetMediaInfoResponse>
          <NrTracks>1</NrTracks>
          <MediaDuration>NOT_IMPLEMENTED</MediaDuration>
          <CurrentURI>\(vliURI)</CurrentURI>
          <CurrentURIMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns:r=&quot;urn:schemas-rinconnetworks-com:metadata-1-0/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;spotify&quot; parentID=&quot;0&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;Spotify&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.linein&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
        </GetMediaInfoResponse>
        """.utf8))
        let parsedDormant = TransportService.parsePlayback(
            transportInfo: dormantTransport,
            positionInfo: dormantPosition,
            mediaInfo: dormantMedia,
            coordinatorEndpoint: endpoint,
            sampledAt: Date(timeIntervalSinceReferenceDate: 500)
        )
        #expect(parsedDormant == .stopped)

        // 2. External Spotify context on local computer maps to "Playing on This computer"
        let trackURI = SpotifyURI("spotify:track:5TbTOkgK8UAjtjIuIVPAjE")!
        let computerCtx = SpotifyTrackContext(
            uri: trackURI,
            metadata: SpotifyTrackMetadata(
                title: "DON'T BELIEVE IT",
                artist: "Kid Cudi",
                album: "INSANO",
                artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b273a1b2c3"),
                duration: .seconds(176)
            ),
            position: .seconds(117),
            contextTitle: "Playlist \"26\"",
            contextURI: "spotify:playlist:3wdvPfaJKS9AnZzRX35gyW",
            deviceID: "2bb28805ce4cd7875feba40e70eebe2ffebd99e5",
            deviceName: "Dylan’s Any MBP",
            deviceType: "Computer",
            isPlaying: true,
            upNext: [
                QueueItem(
                    id: "1",
                    title: "Next Up Track",
                    artist: "Kid Cudi",
                    spotifyURI: SpotifyURI("spotify:track:2mqTtvbKxH7SoEQ2oGAnsA")
                ),
            ]
        )
        #expect(computerCtx.externalDeviceDisplayName == "This computer")
        #expect(computerCtx.externalPlaybackLabel == "Playing on This computer")

        let phoneCtx = SpotifyTrackContext(
            uri: trackURI,
            metadata: computerCtx.metadata,
            position: .seconds(40),
            deviceName: "Dylan’s iPhone",
            deviceType: "Smartphone",
            isPlaying: true
        )
        #expect(phoneCtx.externalDeviceDisplayName == "Dylan’s iPhone")
        #expect(phoneCtx.externalPlaybackLabel == "Playing on Dylan’s iPhone")

        // 3. When all Sonos groups are idle and Spotify plays on the computer, SconeStore exposes
        // state.externalSpotify and one-click transfer invokes playOnSonosGroup (Connect transfer).
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let bedroom = speaker(House.bedroom, room: "Bedroom Speaker", ip: "192.168.68.73", volume: .v25)
        let dining = speaker(House.dining, room: "Dining Room Speaker", ip: "192.168.68.82", volume: .v25)
        let idleSnap = snapshot(
            [bedroom, dining],
            coordinatorOf: [
                House.bedroom: House.bedroom,
                House.dining: House.bedroom,
            ],
            status: [
                GroupID(coordinator: House.bedroom): GroupStatus(playback: .stopped, volume: .v25),
            ]
        )

        let directTransferSpotify = CountingSpotify(
            response: .success(computerCtx),
            playOnSonosGroupResult: true
        )
        let sonosRecorder1 = RecordingSonos(yielded: [idleSnap])
        let store1 = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: sonosRecorder1,
            spotify: directTransferSpotify
        )
        await store1.run()

        #expect(store1.state.externalSpotify?.metadata.title == "DON'T BELIEVE IT")
        #expect(store1.state.externalSpotify?.externalPlaybackLabel == "Playing on This computer")

        let group1 = try #require(store1.state.groups.first)
        store1.togglePlayOrHandOffSpotify(for: group1)
        for _ in 0..<20 where directTransferSpotify.transferredRooms.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(directTransferSpotify.transferredRooms.first?.coordinator == "Bedroom Speaker")
        #expect(directTransferSpotify.transferredRooms.first?.members.contains("Dining Room Speaker") == true)
        #expect(store1.state.externalSpotify == nil)
        if let activeGroup = store1.state.groups.first,
           case .playing(.track(let transferredTrack), _, _) = activeGroup.playback {
            #expect(transferredTrack.title == "DON'T BELIEVE IT")
            #expect(transferredTrack.artist == "Kid Cudi")
        } else {
            Issue.record("expected group to transition to playing after Connect transfer")
        }

        // 4. When the Sonos coordinator is dormant and not in Spotify's Connect device list yet
        // (playOnSonosGroup returns false), SconeStore wakes the group via .enqueueAndPlaySpotify
        // at the current position and pauses the computer playback without sending raw UPnP Play.
        let wakeTransferSpotify = CountingSpotify(
            response: .success(computerCtx),
            playOnSonosGroupResult: false
        )
        let sonosRecorder2 = RecordingSonos(yielded: [idleSnap])
        let store2 = SconeStore(
            loaded: LoadedFiles(cache: nil, positions: nil, quarantined: []),
            files: files,
            sonos: sonosRecorder2,
            spotify: wakeTransferSpotify
        )
        await store2.run()

        let group2 = try #require(store2.state.groups.first)
        store2.togglePlayOrHandOffSpotify(for: group2)
        for _ in 0..<20 where sonosRecorder2.commands.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sonosRecorder2.commands.first == .resumeSpotifyConnect(group: group2.id))
        let wakeCmd = try #require(sonosRecorder2.commands.last)
        if case .enqueueAndPlaySpotify(let uri, let meta, let coord, let pos, let ctxURI, let upNext) = wakeCmd {
            #expect(uri == trackURI)
            #expect(meta.title == "DON'T BELIEVE IT")
            #expect(coord == GroupID(coordinator: House.bedroom))
            #expect(pos == .seconds(117))
            #expect(ctxURI == SpotifyURI("spotify:playlist:3wdvPfaJKS9AnZzRX35gyW"))
            #expect(upNext.count == 1)
        } else {
            Issue.record("expected .enqueueAndPlaySpotify, got \(wakeCmd)")
        }
        #expect(wakeTransferSpotify.pauseCount == 1)
    }
}

@MainActor
private final class CountingSpotify: SpotifySource {
    let response: Result<SpotifyTrackContext, SpotifyBridgeError>
    let playOnSonosGroupResult: Bool
    var callCount = 0
    var pauseCount = 0
    var shuffleRequests: [Bool] = []
    var transferredRooms: [(coordinator: String, members: [String])] = []

    init(
        response: Result<SpotifyTrackContext, SpotifyBridgeError>,
        playOnSonosGroupResult: Bool = false
    ) {
        self.response = response
        self.playOnSonosGroupResult = playOnSonosGroupResult
    }

    func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        callCount += 1
        switch response {
        case .success(let ctx): return ctx
        case .failure(let err): throw err
        }
    }

    func pauseSourcePlayback() async {
        pauseCount += 1
    }

    func resumeSourcePlayback() async -> Bool { false }

    func setShuffle(_ isOn: Bool) async throws(SpotifyBridgeError) {
        shuffleRequests.append(isOn)
    }

    func playOnSonosGroup(
        coordinatorRoomName: String,
        memberRoomNames: [String],
        context: SpotifyTrackContext?
    ) async -> Bool {
        transferredRooms.append((coordinatorRoomName, memberRoomNames))
        return playOnSonosGroupResult
    }
}

@MainActor
private final class RecordingSonos: SonosControl {
    let yielded: [HouseholdSnapshot]
    let spotifyConnectGroups: Set<GroupID>
    var commands: [SonosCommand] = []

    init(yielded: [HouseholdSnapshot], spotifyConnectGroups: Set<GroupID> = []) {
        self.yielded = yielded
        self.spotifyConnectGroups = spotifyConnectGroups
    }

    nonisolated func snapshots() -> AsyncStream<HouseholdSnapshot> {
        let items = yielded
        return AsyncStream { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish()
        }
    }

    func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome {
        commands.append(command)
        if case .resumeSpotifyConnect(let group) = command, !spotifyConnectGroups.contains(group) {
            throw .unsupportedForCurrentSource
        }
        return .applied
    }
}

private struct ScriptedSonos: SonosControl {
    var yielded: [HouseholdSnapshot]

    func snapshots() -> AsyncStream<HouseholdSnapshot> {
        let yielded = yielded
        return AsyncStream { continuation in
            for snapshot in yielded { continuation.yield(snapshot) }
            continuation.finish()
        }
    }

    func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome {
        .alreadySatisfied
    }
}

@MainActor
private final class IdleSpotify: SpotifySource {
    func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        throw .nothingPlaying
    }

    func pauseSourcePlayback() async {}

    func resumeSourcePlayback() async -> Bool { false }
}

private func alone(_ ids: [SpeakerUUID]) -> [SpeakerUUID: SpeakerUUID] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
}

private func topology(_ pairs: [SpeakerUUID: SpeakerUUID]) -> Topology {
    guard let topology = Topology(coordinatorOf: pairs) else { preconditionFailure("illegal topology") }
    return topology
}

private func speaker(
    _ id: SpeakerUUID, room: String, ip: String = "192.168.68.58", volume: DiscreteVolume = .v20
) -> Speaker {
    Speaker(
        id: id, roomName: room, model: .era100,
        reachability: .online(ip: ip, rssi: -40, noiseFloor: -98), volume: volume)
}

private func soundbarWithRearSatellite(reachability: ReachabilityState) -> Speaker {
    Speaker(
        id: House.living, roomName: "Living Room", model: .arc, reachability: reachability, volume: .v20,
        bondedSatellites: [BondedSatellite(
            id: SpeakerUUID(rawValue: "RINCON_F0F6C1AAF58601400")!, parentID: House.living, role: .rearLeft,
            modelNumber: "S39", displayName: "Sonos Era 100", isOnline: true, linkQuality: 63)])
}

private func homeCache(_ speakers: [Speaker], networkName: String? = nil) -> CachedSpeakersFile {
    CachedSpeakersFile(
        current: House.household,
        households: [House.household: HouseholdRoster(speakers: speakers, rf: .empty, networkName: networkName)])
}

private func snapshot(
    _ speakers: [Speaker],
    coordinatorOf: [SpeakerUUID: SpeakerUUID],
    status: [GroupID: GroupStatus] = [:],
    rf: RFPeerMatrix = .empty,
    at date: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    household: HouseholdID = House.household
) -> HouseholdSnapshot {
    HouseholdSnapshot(
        household: household,
        observedAt: date,
        speakers: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) }),
        topology: topology(coordinatorOf),
        groupStatus: status,
        rf: rf)
}

private func expectIdempotent(
    _ target: TopologyTarget, from start: Topology, sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .steps(let steps, let skipped) = target.plan(from: start) else {
        Issue.record("expected steps", sourceLocation: sourceLocation)
        return
    }
    let end = steps.reduce(start) { $0.applying($1) }
    #expect(target.isSatisfied(by: end, ignoring: skipped), sourceLocation: sourceLocation)
    #expect(target.plan(from: end) == .steps([], skipped: skipped), sourceLocation: sourceLocation)
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "scone-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
