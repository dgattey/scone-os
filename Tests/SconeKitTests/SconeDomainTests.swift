import Foundation
import SconeDomain
import SpotifyBridge
import Testing
@testable import SconeStore

private enum House {
    static let kitchen = SpeakerUUID(rawValue: "RINCON_F0F6C1AAD22801400")!
    static let dining = SpeakerUUID(rawValue: "RINCON_F0F6C1C47CEA01400")!
    static let living = SpeakerUUID(rawValue: "RINCON_542A1B95A13A01400")!
    static let bedroom = SpeakerUUID(rawValue: "RINCON_542A1B5F088401400")!
    static let guest = SpeakerUUID(rawValue: "RINCON_542A1B5F08A001400")!
    static let basement = SpeakerUUID(rawValue: "RINCON_C4387523117601400")!
}

struct VolumeTests {
    @Test(arguments: [
        (22, DiscreteVolume.v20),
        (23, DiscreteVolume.v25),
        (0, DiscreteVolume.v0),
        (100, DiscreteVolume.v100),
        (-4, DiscreteVolume.v0),
        (140, DiscreteVolume.v100),
        (2, DiscreteVolume.v0),
        (3, DiscreteVolume.v5),
    ])
    func snapsPercent(_ percent: Int, to expected: DiscreteVolume) {
        #expect(DiscreteVolume(snappingPercent: percent) == expected)
    }

    @Test func snapsFractionAndStepsByDetents() {
        #expect(DiscreteVolume(snappingFraction: 0.22) == .v20)
        #expect(DiscreteVolume(snappingFraction: 0.225) == .v25)
        #expect(DiscreteVolume(snappingFraction: 1.4) == .v100)
        #expect(DiscreteVolume(snappingFraction: -0.2) == .v0)
        #expect(DiscreteVolume(snappingFraction: .nan) == .v0)
        #expect(DiscreteVolume(snappingFraction: .infinity) == .v0)
        #expect(DiscreteVolume.v0.stepped(by: -1) == .v0)
        #expect(DiscreteVolume.v100.stepped(by: 1) == .v100)
        #expect(DiscreteVolume.v95.stepped(by: 1) == .v100)
        #expect(DiscreteVolume.v20.stepped(by: 3) == .v35)
        #expect(DiscreteVolume.v20.stepped(by: -5) == .v0)
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
        #expect(ungroup.plan(from: diningLeads) == .steps([.makeStandalone(House.dining)], skipped: []))
        expectIdempotent(ungroup, from: diningLeads)
        let apart = diningLeads.applying(.makeStandalone(House.dining))
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
    @Test func householdRoomsKeepProbePriorsWithoutPeerReadings() {
        let layout = FloorplanLayout.infer(
            rooms: [House.basement, House.kitchen, House.guest, House.living, House.bedroom, House.dining],
            matrix: .empty)
        #expect(layout[House.kitchen] == RoomCoordinate(clampingX: 0.24, y: 0.24))
        #expect(layout[House.dining] == RoomCoordinate(clampingX: 0.54, y: 0.24))
        #expect(layout[House.living] == RoomCoordinate(clampingX: 0.80, y: 0.34))
        #expect(layout[House.bedroom] == RoomCoordinate(clampingX: 0.24, y: 0.64))
        #expect(layout[House.guest] == RoomCoordinate(clampingX: 0.54, y: 0.64))
        #expect(layout[House.basement] == RoomCoordinate(clampingX: 0.80, y: 0.74))
        #expect(FloorplanLayout.infer(rooms: [], matrix: .empty).isEmpty)
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

        matrix.record(House.bedroom, House.guest, from: 15, to: 0)
        #expect(matrix.band(House.guest, House.bedroom) == .weak)
        let weak = FloorplanLayout.infer(rooms: [House.bedroom, House.guest], matrix: matrix)
        #expect(weak[House.bedroom] == RoomCoordinate(clampingX: 0.24, y: 0.64))
        #expect(weak[House.guest] == RoomCoordinate(clampingX: 0.54, y: 0.64))

        matrix.record(House.guest, House.bedroom, from: 22, to: 20)
        let moderate = FloorplanLayout.infer(rooms: [House.guest, House.bedroom], matrix: matrix)
        #expect(moderate[House.bedroom] == RoomCoordinate(clampingX: 0.25, y: 0.64))
        #expect(moderate[House.guest] == RoomCoordinate(clampingX: 0.53, y: 0.64))

        matrix.record(House.bedroom, House.guest, from: 42, to: 43)
        matrix.record(House.bedroom, House.guest, from: 10, to: 12)
        #expect(matrix.band(House.bedroom, House.guest) == .strong)
        let strong = FloorplanLayout.infer(rooms: [House.bedroom, House.guest], matrix: matrix)
        #expect(strong[House.bedroom] == RoomCoordinate(clampingX: 0.26, y: 0.64))
        #expect(strong[House.guest] == RoomCoordinate(clampingX: 0.52, y: 0.64))
    }

    @Test func unknownRoomsLandOnASortedGridAndStrongLinksNudgeThem() {
        let first = SpeakerUUID(rawValue: "RINCON_00000000000101400")!
        let second = SpeakerUUID(rawValue: "RINCON_00000000000201400")!
        let reversed = FloorplanLayout.infer(rooms: [second, first], matrix: .empty)
        #expect(reversed[first] == RoomCoordinate(clampingX: 0.33, y: 0.50))
        #expect(reversed[second] == RoomCoordinate(clampingX: 0.67, y: 0.50))
        #expect(FloorplanLayout.infer(rooms: [first], matrix: .empty)[first] == RoomCoordinate(clampingX: 0.50, y: 0.50))

        var matrix = RFPeerMatrix.empty
        matrix.record(House.kitchen, first, from: 40, to: 36)
        let nudged = FloorplanLayout.infer(rooms: [first, House.kitchen], matrix: matrix)
        #expect(nudged[House.kitchen] == RoomCoordinate(clampingX: 0.26, y: 0.26))
        #expect(nudged[first] == RoomCoordinate(clampingX: 0.48, y: 0.48))
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
}

struct SconeStateTests {
    @Test func firstLaunchSeedsHouseholdPresetsAndASavedFileDoesNot() {
        let seeded = SconeState(loaded: LoadedFiles(cache: nil, presets: nil, positions: nil, quarantined: []))
        #expect(seeded.presets.map(\.name) == ["Kitchen + Dining", "Main Floor", "Upstairs", "Everywhere"])
        #expect(seeded.presets[0].coordinatorUUID == House.kitchen)
        #expect(seeded.presets[0].memberUUIDs == [House.dining])
        #expect(seeded.presets[1].coordinatorUUID == House.living)
        #expect(seeded.presets[1].memberUUIDs == [House.kitchen, House.dining])
        #expect(seeded.presets[2].coordinatorUUID == House.bedroom)
        #expect(seeded.presets[2].memberUUIDs == [House.guest])
        #expect(seeded.presets[3].coordinatorUUID == House.living)
        #expect(seeded.presets[3].memberUUIDs == [House.kitchen, House.dining, House.bedroom, House.guest, House.basement])

        let custom = PresetPill(name: "Movie", coordinatorUUID: House.living, memberUUIDs: [])
        let restored = SconeState(loaded: LoadedFiles(
            cache: nil, presets: PresetsFile(presets: [custom]), positions: nil, quarantined: []))
        #expect(restored.presets.map(\.name) == ["Movie"])

        let quarantined = SconeState(loaded: LoadedFiles(
            cache: nil, presets: nil, positions: nil, quarantined: ["presets.json.corrupt-10"]))
        #expect(quarantined.alert == .quarantined(fileName: "presets.json.corrupt-10"))
        #expect(quarantined.presets.map(\.name) == ["Kitchen + Dining", "Main Floor", "Upstairs", "Everywhere"])
    }

    @Test func renameTrimsAndLeavesBlankOrUnknownIdsAlone() {
        var state = SconeState(loaded: LoadedFiles(cache: nil, presets: nil, positions: nil, quarantined: []))
        let id = state.presets[0].id
        state.renamePreset(id, to: "  Downstairs  ")
        #expect(state.presets[0].name == "Downstairs")
        state.renamePreset(id, to: "   ")
        #expect(state.presets[0].name == "Downstairs")
        state.renamePreset(PresetID(), to: "Nope")
        #expect(state.presets.map(\.name) == ["Downstairs", "Main Floor", "Upstairs", "Everywhere"])
    }

    @Test func absorbKeepsUnseenRoomsAndPinsWinOverInference() {
        let old = Date(timeIntervalSinceReferenceDate: 10)
        let basement = Speaker(
            id: House.basement, roomName: "Basement Speaker", model: .move(battery: nil),
            reachability: .offline(lastKnownIP: "192.168.68.95", lastSeenAt: old), volume: .v10)
        var state = SconeState(loaded: LoadedFiles(
            cache: CachedSpeakersFile(speakers: [basement], rf: .empty),
            presets: PresetsFile(presets: []),
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
        #expect(state.floorplan[0].coordinate == RoomCoordinate(clampingX: 0.80, y: 0.74))
        #expect(state.floorplan[1].coordinate == RoomCoordinate(clampingX: 0.24, y: 0.24))
        #expect(state.floorplan[1].placement == .inferred)
        #expect(state.floorplan[1].group == GroupID(coordinator: House.kitchen))
        #expect(state.floorplan[1].speaker.reachability.isOnline)
        let cachedKitchen = state.persisted.cache.speakers.first { $0.id == House.kitchen }
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
            cache: nil, presets: PresetsFile(presets: []), positions: nil, quarantined: []))
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
}

struct SconeFileTests {
    @Test func saveRoundTripsAndQuarantinesCorruptUserFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "nested/house")
        let files = SconeFiles(directory: nested)
        let preset = PresetPill(name: "Movie", coordinatorUUID: House.living, memberUUIDs: [House.kitchen])
        try files.save(PresetsFile(presets: [preset]), to: .presets)
        guard case .loaded(let loaded) = files.load(FileSlot.presets) else {
            Issue.record("expected presets to load")
            return
        }
        #expect(loaded.presets == [preset])

        let allMissing = SconeFiles(directory: directory.appending(path: "absent")).loadAll()
        #expect(allMissing.cache == nil)
        #expect(allMissing.presets == nil)
        #expect(allMissing.positions == nil)
        #expect(allMissing.quarantined == [])

        try Data("not json".utf8).write(to: nested.appending(path: "presets.json"))
        try Data("not json".utf8).write(to: nested.appending(path: "cached-speakers.json"))
        let recovered = files.loadAll()
        #expect(recovered.presets == nil)
        #expect(recovered.cache == nil)
        #expect(recovered.quarantined.count == 1)
        let quarantined = try #require(recovered.quarantined.first)
        #expect(quarantined.hasPrefix("presets.json.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: nested.appending(path: quarantined).path))
        #expect(!FileManager.default.fileExists(atPath: nested.appending(path: "presets.json").path))
        #expect(!FileManager.default.fileExists(atPath: nested.appending(path: "cached-speakers.json").path))
    }

    @Test @MainActor func userEditsWriteImmediatelyAndTheCacheWaitsThirtySeconds() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = SconeFiles(directory: directory)
        let store = SconeStore(
            loaded: LoadedFiles(cache: nil, presets: nil, positions: nil, quarantined: []),
            files: files,
            sonos: ScriptedSonos(yielded: []),
            spotify: IdleSpotify())
        let id = store.state.presets[0].id
        store.renamePreset(id, to: "Downstairs")
        guard case .loaded(let presets) = files.load(FileSlot.presets) else {
            Issue.record("expected presets.json")
            return
        }
        #expect(presets.presets.map(\.name) == ["Downstairs", "Main Floor", "Upstairs", "Everywhere"])

        let pin = RoomCoordinate(clampingX: 0.12, y: 0.88)
        store.moveRoom(House.kitchen, to: pin)
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
            loaded: LoadedFiles(cache: nil, presets: PresetsFile(presets: []), positions: nil, quarantined: []),
            files: files,
            sonos: ScriptedSonos(yielded: [first, second]),
            spotify: IdleSpotify())
        await sweeping.run()
        guard case .loaded(let cache) = files.load(FileSlot.cachedSpeakers) else {
            Issue.record("expected cached-speakers.json")
            return
        }
        #expect(cache.speakers.first?.volume == .v20)
        #expect(cache.speakers.first?.reachability == .offline(lastKnownIP: "192.168.68.58", lastSeenAt: firstDate))
        #expect(cache.rf.band(House.bedroom, House.guest) == nil)
        #expect(sweeping.state.persisted.cache.speakers.first?.volume == .v40)
        #expect(sweeping.state.persisted.cache.rf.band(House.bedroom, House.guest) == .strong)
    }

    @Test func discoverySeedsKeepCachedAddressesAheadOfTheHouseholdFallbacks() {
        #expect(SconeStore.mergedSeedIPs(cached: []) == [
            "192.168.68.58", "192.168.68.71", "192.168.68.73",
            "192.168.68.90", "192.168.68.92", "192.168.68.95",
        ])
        #expect(SconeStore.mergedSeedIPs(cached: ["10.0.0.8", "192.168.68.71", "10.0.0.8"]) == [
            "10.0.0.8", "192.168.68.71", "192.168.68.58", "192.168.68.73",
            "192.168.68.90", "192.168.68.92", "192.168.68.95",
        ])
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

private func snapshot(
    _ speakers: [Speaker],
    coordinatorOf: [SpeakerUUID: SpeakerUUID],
    status: [GroupID: GroupStatus] = [:],
    rf: RFPeerMatrix = .empty,
    at date: Date = Date(timeIntervalSinceReferenceDate: 1_000)
) -> HouseholdSnapshot {
    HouseholdSnapshot(
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
