import SwiftUI
import SconeDomain
import SconeStore
import SpotifyBridge

func playbackIsActive(_ playback: PlaybackState) -> Bool {
    if case .playing = playback { true } else { false }
}

enum LaunchView {
    static func requestsGroup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_INITIAL_VIEW"]?.lowercased() == "group" { return true }
        if arguments.contains(where: { $0.lowercased() == "--initial-view=group" }) { return true }
        guard let index = arguments.firstIndex(of: "--initial-view"),
              arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1].lowercased() == "group"
    }
}

@MainActor
func joinedSpeaker(from items: [String], onto target: SpeakerUUID, store: SconeStore) -> Bool {
    guard let raw = items.first, let member = SpeakerUUID(rawValue: raw), member != target else { return false }
    store.group(member: member, onto: target)
    return true
}

enum SidebarDestination: Hashable {
    case home
    case group(GroupID)
    case speaker(SpeakerUUID)
}

public struct SconeRootView: View {
    @Environment(SconeStore.self) private var store
    @State private var selection: SidebarDestination? = .home
    @State private var appliedLaunch = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SconeOS")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MidnightGlass.gold)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if let alert = store.state.alert {
                AlertBanner(message: alertMessage(alert)) {
                    store.dismissAlert()
                }
                .padding(.top, 12)
                .padding(.trailing, 18)
            }
        }
        .onChange(of: store.state.groups.map(\.id), initial: true) { _, ids in
            if case .group(let id) = selection, !ids.contains(id), appliedLaunch {
                selection = .home
            }
            applyLaunchSelection()
        }
        .onChange(of: offlineSpeakers.map(\.id)) { _, ids in
            guard case .speaker(let id) = selection, !ids.contains(id) else { return }
            if let group = store.state.groups.first(where: { $0.speakers.contains { $0.id == id } }) {
                selection = .group(group.id)
            } else {
                selection = .home
            }
        }
        .task { await store.run() }
    }

    private var sidebar: some View {
        ZStack {
            MidnightBackground()
            Rectangle().fill(.ultraThinMaterial)
            List(selection: $selection) {
                HStack(spacing: 10) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(selection == .home ? MidnightGlass.gold : Color.white.opacity(0.82))
                    Text("Home")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .tag(SidebarDestination.home)
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                .listRowBackground(rowBackground(selected: selection == .home))
                .listRowSeparator(.hidden)

                ForEach(store.state.groups) { group in
                    SidebarGroupRow(group: group)
                        .tag(SidebarDestination.group(group.id))
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(rowBackground(selected: selection == .group(group.id)))
                        .listRowSeparator(.hidden)
                }
                ForEach(offlineSpeakers) { speaker in
                    SidebarOfflineRow(speaker: speaker)
                        .tag(SidebarDestination.speaker(speaker.id))
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(rowBackground(selected: selection == .speaker(speaker.id)))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(MidnightGlass.copper)
        }
        .navigationSplitViewColumnWidth(min: 248, ideal: 292, max: 360)
    }

    @ViewBuilder private var detail: some View {
        ZStack {
            MidnightBackground()
            switch selection {
            case .home, nil:
                HomePane(onSelectGroup: { selection = .group($0) })
            case .group(let id):
                if let group = store.state.groups.first(where: { $0.id == id }) {
                    GroupDetailView(group: group)
                } else {
                    HomePane(onSelectGroup: { selection = .group($0) })
                }
            case .speaker(let id):
                if let speaker = store.state.speakers.first(where: { $0.id == id }) {
                    OfflineSpeakerDetail(speaker: speaker)
                } else {
                    HomePane(onSelectGroup: { selection = .group($0) })
                }
            }
        }
    }

    private var offlineSpeakers: [Speaker] {
        let grouped = Set(store.state.groups.flatMap { $0.speakers.map(\.id) })
        return store.state.speakers.filter { !$0.reachability.isOnline && !grouped.contains($0.id) }
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? MidnightGlass.copper.opacity(0.22) : Color.clear)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(MidnightGlass.gold.opacity(0.75), lineWidth: 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    private func applyLaunchSelection() {
        guard !appliedLaunch, LaunchView.requestsGroup() else { return }
        let multi = store.state.groups.filter { $0.speakers.count > 1 }
        guard let count = multi.map(\.speakers.count).max(),
              let group = multi.first(where: { $0.speakers.count == count }) else { return }
        selection = .group(group.id)
        appliedLaunch = true
    }

    private func alertMessage(_ alert: SconeAlert) -> String {
        switch alert {
        case .commandFailed(_, let error):
            switch error {
            case .speakerUnreachable:
                "A room did not answer"
            case .groupDissolved:
                "That arrangement changed"
            case .notConverged:
                "The rooms did not settle"
            case .unsupportedForCurrentSource:
                "This source cannot skip"
            case .spotifyNotLinkedOnSonos:
                "Spotify is not linked"
            case .speakerRejected:
                "A room refused"
            }
        case .partiallyApplied:
            "Some rooms were out of reach"
        case .spotify(let error):
            switch error {
            case .notConnected:
                "Spotify is not connected"
            case .nothingPlaying:
                "Nothing is playing"
            case .unplayableOnSonos:
                "That track cannot play here"
            case .automationDenied:
                "Spotify access was denied"
            case .authorizationFailed:
                "Spotify did not connect"
            case .network:
                "The network did not answer"
            }
        case .quarantined:
            "A saved file could not be read"
        }
    }
}

private struct HomePane: View {
    @Environment(SconeStore.self) private var store
    var onSelectGroup: (GroupID) -> Void

    private var featuredGroup: SonosGroup? {
        let groups = store.state.groups
        return groups.first { playbackIsActive($0.playback) }
            ?? groups.first { $0.speakers.count > 1 }
            ?? groups.first { $0.playback.nowPlaying != nil }
            ?? groups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PresetPillsBar()
                .padding(.top, 4)
            FloorplanMapView()
            if let group = featuredGroup {
                NowPlayingDock(group: group, onOpen: { onSelectGroup(group.id) })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
    }
}

private struct NowPlayingDock: View {
    @Environment(SconeStore.self) private var store
    var group: SonosGroup
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    dockArt
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(MidnightGlass.gold.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                dockTransportButton("backward.fill", enabled: canSkip, prominent: false) {
                    store.send(.previousTrack(group: group.id))
                }
                dockTransportButton(
                    playbackIsActive(group.playback) ? "pause.fill" : "play.fill",
                    enabled: true,
                    prominent: true
                ) {
                    store.togglePlayOrHandOffSpotify(for: group)
                }
                dockTransportButton("forward.fill", enabled: canSkip, prominent: false) {
                    store.send(.nextTrack(group: group.id))
                }
            }

            DiscreteVolumeControl(volume: group.volume, compact: true) { volume in
                let target: VolumeTarget = group.speakers.count > 1
                    ? .group(group.id)
                    : .speaker(group.coordinator.id)
                store.send(.setVolume(volume, for: target))
            }
            .frame(width: 210)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .midnightGlass(glowing: playbackIsActive(group.playback), radius: 20)
    }

    @ViewBuilder private var dockArt: some View {
        if case .track(let track) = group.playback.nowPlaying, let url = track.artworkURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    WaveformArt(active: playbackIsActive(group.playback))
                }
            }
        } else {
            WaveformArt(active: playbackIsActive(group.playback))
        }
    }

    private var primaryTitle: String {
        switch group.playback.nowPlaying {
        case .track(let track) where !track.title.isEmpty:
            track.title
        case .tvAudio:
            "TV"
        case .stream(let title):
            title ?? group.displayName
        default:
            group.displayName
        }
    }

    private var subtitle: String? {
        switch group.playback.nowPlaying {
        case .track(let track):
            if let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
                return "\(artist) · \(group.displayName)"
            }
            return track.title.isEmpty ? nil : group.displayName
        case .tvAudio, .stream:
            return group.displayName
        case nil:
            return nil
        }
    }

    private var canSkip: Bool {
        guard case .track(let track) = group.playback.nowPlaying else { return false }
        return track.queuePosition != nil
    }

    private func dockTransportButton(
        _ system: String,
        enabled: Bool,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: prominent ? 13 : 11, weight: .bold))
                .foregroundStyle(enabled ? (prominent ? MidnightGlass.ink : Color.white) : Color.white.opacity(0.28))
                .frame(width: prominent ? 34 : 28, height: prominent ? 34 : 28)
                .background {
                    if prominent {
                        Circle().fill(MidnightGlass.gold)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.16), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

private struct AlertBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(MidnightGlass.gold)
                .frame(width: 6, height: 6)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .midnightGlass(glowing: true, radius: 16)
    }
}

private struct SidebarGroupRow: View {
    @Environment(SconeStore.self) private var store
    var group: SonosGroup
    @State private var targeted = false

    var body: some View {
        row.overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MidnightGlass.gold, lineWidth: 1.5)
                    .shadow(color: MidnightGlass.copper.opacity(0.85), radius: 8)
            }
        }
    }

    @ViewBuilder private var row: some View {
        let base = rowBody.dropDestination(for: String.self) { items, _ in
            joinedSpeaker(from: items, onto: group.coordinator.id, store: store)
        } isTargeted: { targeted = $0 }
        if group.speakers.count == 1 {
            base.draggable(group.coordinator.id.rawValue) { dragPreview(group.coordinator) }
        } else {
            base
        }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if group.speakers.count == 1 {
                    SpeakerSilhouetteView(
                        model: group.coordinator.model,
                        isOnline: group.coordinator.reachability.isOnline,
                        isPlaying: playbackIsActive(group.playback),
                        size: 36)
                }
                Text(group.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if playbackIsActive(group.playback) {
                    PlayingMark()
                }
            }
            if group.speakers.count > 1 {
                ForEach(group.speakers) { speaker in
                    chip(speaker)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func chip(_ speaker: Speaker) -> some View {
        HStack(spacing: 8) {
            SpeakerSilhouetteView(
                model: speaker.model,
                isOnline: speaker.reachability.isOnline,
                isPlaying: playbackIsActive(group.playback),
                isGrouped: true,
                size: 28)
            Text(RoomNaming.shortName(speaker.roomName, merged: false))
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !speaker.reachability.isOnline {
                OfflinePill()
            }
            Button {
                store.send(.ungroup(member: speaker.id))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
        }
        .padding(.leading, 4)
        .draggable(speaker.id.rawValue) { dragPreview(speaker) }
    }
}

private struct SidebarOfflineRow: View {
    var speaker: Speaker

    var body: some View {
        HStack(spacing: 10) {
            SpeakerSilhouetteView(model: speaker.model, isOnline: false, size: 36)
            Text(RoomNaming.shortName(speaker.roomName, merged: false))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            OfflinePill()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .draggable(speaker.id.rawValue) { dragPreview(speaker) }
    }
}

private func dragPreview(_ speaker: Speaker) -> some View {
    Text(RoomNaming.shortName(speaker.roomName, merged: false))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(MidnightGlass.gold)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(MidnightGlass.obsidian))
        .overlay(Capsule().strokeBorder(MidnightGlass.gold.opacity(0.7), lineWidth: 1))
}
