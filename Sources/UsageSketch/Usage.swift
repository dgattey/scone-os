import AuthenticationServices
import SconeDomain
import SconeStore
import SpotifyBridge
import SwiftUI

struct SconeOSApp: App {
    @State private var spotify: SpotifyBridge
    @State private var store: SconeStore

    init() {
        let spotify = SpotifyBridge(clientID: "<spotify client id>", redirectURI: URL(string: "sconeos://spotify-callback")!)
        _spotify = State(initialValue: spotify)
        _store = State(initialValue: SconeStore.live(spotify: spotify))
    }

    var body: some Scene {
        WindowGroup {
            HouseView()
                .environment(store)
                .environment(spotify)
                .task { await store.run() }
        }
    }
}

struct HouseView: View {
    @Environment(SconeStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            if case .away(let lastSeenAt) = store.state.connection {
                Text("Away from home. Showing rooms as of \(lastSeenAt?.formatted() ?? "your last visit").")
            }
            PresetPillsRow()
            FloorplanCanvas()
            ForEach(store.state.groups) { group in
                GroupCard(group: group)
            }
        }
    }
}

struct PresetPillsRow: View {
    @Environment(SconeStore.self) private var store

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(store.state.presets) { preset in
                    Button(preset.name) { store.send(.applyPreset(preset)) }
                        .buttonStyle(.borderedProminent)
                        .tint(store.state.isActive(preset) ? .accentColor : .secondary)
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.deletePreset(preset.id) }
                        }
                }
            }
        }
    }
}

struct GroupCard: View {
    @Environment(SconeStore.self) private var store
    let group: SonosGroup

    var body: some View {
        VStack(alignment: .leading) {
            Text(group.displayName).font(.headline)
            if case .track(let track) = group.playback.nowPlaying {
                Text(track.title)
                if let artist = track.artist { Text(artist).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Previous") { store.send(.previousTrack(group: group.id)) }.disabled(!canSkip)
                Button(isPlaying ? "Pause" : "Play") {
                    store.send(.playPause(isPlaying ? .pause : .play, group: group.id))
                }
                Button("Next") { store.send(.nextTrack(group: group.id)) }.disabled(!canSkip)
            }
            VolumeDial(volume: group.volume) { store.send(.setVolume($0, for: .group(group.id))) }
            ForEach(group.speakers) { speaker in
                VolumeDial(volume: speaker.volume) { store.send(.setVolume($0, for: .speaker(speaker.id))) }
            }
            Button("Play from Spotify here") { store.handOffSpotify(to: group.id) }
            Button("Save as preset") { store.savePreset(from: group.id) }
        }
    }

    private var isPlaying: Bool {
        if case .playing = group.playback { true } else { false }
    }

    private var canSkip: Bool {
        if case .track(let track) = group.playback.nowPlaying { track.queuePosition != nil } else { false }
    }
}

/// 21 detents. The slider can only report values the type can hold.
struct VolumeDial: View {
    let volume: DiscreteVolume
    let onChange: (DiscreteVolume) -> Void

    var body: some View {
        HStack {
            Button("-") { onChange(volume.stepped(by: -1)) }
            Slider(
                value: Binding(
                    get: { volume.fraction },
                    set: { fraction in
                        let snapped = DiscreteVolume(snappingFraction: fraction)
                        if snapped != volume { onChange(snapped) }
                    }),
                in: 0...1, step: 0.05)
            Button("+") { onChange(volume.stepped(by: 1)) }
        }
    }
}

struct FloorplanCanvas: View {
    @Environment(SconeStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(store.state.floorplan) { node in
                    RoomNode(node: node)
                        .position(
                            x: node.coordinate.x * geometry.size.width,
                            y: node.coordinate.y * geometry.size.height)
                        .gesture(
                            DragGesture(coordinateSpace: .named("floorplan")).onEnded { drag in
                                store.moveRoom(
                                    node.id,
                                    to: RoomCoordinate(
                                        clampingX: drag.location.x / geometry.size.width,
                                        y: drag.location.y / geometry.size.height))
                            }
                        )
                        .contextMenu {
                            ForEach(store.state.groups.filter { $0.id != node.group }) { group in
                                Button("Join \(group.displayName)") {
                                    store.send(.group(member: node.id, intoCoordinator: group.id))
                                }
                            }
                            Button("Leave group") { store.send(.ungroup(member: node.id)) }
                                .disabled(node.group == nil)
                            if node.placement == .pinned {
                                Button("Reset position") { store.resetRoom(node.id) }
                            }
                        }
                }
            }
            .coordinateSpace(.named("floorplan"))
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }
}

struct RoomNode: View {
    let node: FloorplanNode

    var body: some View {
        VStack {
            Text(RoomNaming.shortName(node.speaker.roomName, merged: false))
            if let battery = node.speaker.model.battery {
                Text("\(battery.levelPercent)%\(battery.isOnCharger ? " charging" : "")")
            }
            ForEach(node.speaker.model.satellites) { satellite in
                Text(satellite.role.rawValue).font(.caption2)
            }
        }
        .opacity(node.speaker.reachability.isOnline ? 1 : 0.4)
    }
}

struct SpotifySettings: View {
    @Environment(SpotifyBridge.self) private var spotify
    @Environment(\.webAuthenticationSession) private var session
    @State private var error: SpotifyBridgeError?

    var body: some View {
        switch spotify.authorization {
        case .notConnected:
            Button("Connect Spotify") {
                Task {
                    do throws(SpotifyBridgeError) {
                        try await spotify.connect(using: session)
                    } catch {
                        self.error = error
                    }
                }
            }
        case .connected(let name):
            Button("Disconnect \(name)") { spotify.disconnect() }
        }
    }
}
