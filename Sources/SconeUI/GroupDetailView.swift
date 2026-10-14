import AuthenticationServices
import SwiftUI
import SconeDomain
import SconeStore
import SpotifyBridge

struct GroupDetailView: View {
    @Environment(SconeStore.self) private var store
    @Environment(SpotifyBridge.self) private var spotify
    @Environment(\.webAuthenticationSession) private var session
    var group: SonosGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(group.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                hero
                VStack(spacing: 12) {
                    ForEach(group.speakers) { speaker in
                        SpeakerCard(
                            speaker: speaker,
                            playing: playbackIsActive(group.playback),
                            canRemove: group.speakers.count > 1,
                            onRemove: { store.send(.ungroup(member: speaker.id)) },
                            onVolume: { store.send(.setVolume($0, for: .speaker(speaker.id))) })
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                art
                meta
            }
            VStack(alignment: .leading, spacing: 16) {
                art
                meta
            }
        }
        .padding(18)
        .midnightGlass(glowing: playbackIsActive(group.playback), radius: 24)
    }

    private var art: some View {
        artContent
            .frame(width: 156, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 1)
            }
    }

    @ViewBuilder private var artContent: some View {
        if let artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    WaveformArt(active: playbackIsActive(group.playback))
                @unknown default:
                    WaveformArt(active: playbackIsActive(group.playback))
                }
            }
        } else {
            WaveformArt(active: playbackIsActive(group.playback))
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let titleText {
                Text(titleText)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            if let artistText {
                Text(artistText)
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)
            }
            transport
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            transportButton("backward.fill", enabled: canSkip) {
                store.send(.previousTrack(group: group.id))
            }
            transportButton(playbackIsActive(group.playback) ? "pause.fill" : "play.fill", enabled: true, prominent: true) {
                store.togglePlayOrHandOffSpotify(for: group)
            }
            transportButton("forward.fill", enabled: canSkip) {
                store.send(.nextTrack(group: group.id))
            }
            if case .notConnected = spotify.authorization {
                Button {
                    Task { try? await spotify.connect(using: session) }
                } label: {
                    SpotifyMark()
                        .stroke(MidnightGlass.gold.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Spotify")
                .padding(.leading, 6)
            }
        }
    }

    private func transportButton(
        _ system: String,
        enabled: Bool,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: prominent ? 18 : 14, weight: .bold))
                .foregroundStyle(enabled ? (prominent ? MidnightGlass.ink : Color.white) : Color.white.opacity(0.28))
                .frame(width: prominent ? 52 : 40, height: prominent ? 52 : 40)
                .background {
                    if prominent {
                        Circle().fill(MidnightGlass.gold)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.16), lineWidth: 1))
                .shadow(color: prominent ? MidnightGlass.gold.opacity(0.4) : .clear, radius: 10)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    private var canSkip: Bool {
        guard case .track(let track) = group.playback.nowPlaying else { return false }
        return track.queuePosition != nil
    }

    private var titleText: String? {
        switch group.playback.nowPlaying {
        case .track(let track):
            track.title.isEmpty ? group.displayName : track.title
        case .tvAudio:
            "TV"
        case .stream(let title):
            title ?? group.displayName
        case nil:
            group.displayName
        }
    }

    private var artistText: String? {
        guard case .track(let track) = group.playback.nowPlaying else { return nil }
        guard let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else {
            return nil
        }
        return artist
    }

    private var artworkURL: URL? {
        guard case .track(let track) = group.playback.nowPlaying else { return nil }
        return track.artworkURL
    }
}

struct OfflineSpeakerDetail: View {
    @Environment(SconeStore.self) private var store
    var speaker: Speaker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text(RoomNaming.shortName(speaker.roomName, merged: false))
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.white)
                    OfflinePill()
                }
                SpeakerCard(
                    speaker: speaker,
                    playing: false,
                    canRemove: false,
                    onRemove: {},
                    onVolume: { store.send(.setVolume($0, for: .speaker(speaker.id))) })
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SpeakerCard: View {
    var speaker: Speaker
    var playing: Bool
    var canRemove: Bool
    var onRemove: () -> Void
    var onVolume: (DiscreteVolume) -> Void

    var body: some View {
        HStack(spacing: 14) {
            SpeakerSilhouetteView(
                model: speaker.model,
                isOnline: speaker.reachability.isOnline,
                isPlaying: playing,
                isGrouped: canRemove,
                size: 64)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(RoomNaming.shortName(speaker.roomName, merged: false))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !speaker.reachability.isOnline {
                        OfflinePill()
                    }
                }
                DiscreteVolumeControl(volume: speaker.volume, onChange: onVolume)
            }
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(14)
        .midnightGlass(radius: 20)
    }
}

struct WaveformArt: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = active && !reduceMotion
        TimelineView(.animation(minimumInterval: moving ? 1 / 20 : 60)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<18, id: \.self) { index in
                    let wave = sin(Double(index) * 0.62 + (moving ? time * 3.2 : 0.7))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [MidnightGlass.gold, MidnightGlass.copper.opacity(0.25)],
                                startPoint: .top,
                                endPoint: .bottom))
                        .frame(width: 4, height: 16 + CGFloat((wave + 1) / 2) * 72)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LinearGradient(
                colors: [MidnightGlass.slate, MidnightGlass.obsidian],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
    }
}

private struct SpotifyMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arcs: [(CGFloat, CGFloat)] = [(0.78, -7), (0.56, 1), (0.34, 9)]
        for (scale, dy) in arcs {
            path.addArc(
                center: CGPoint(x: rect.minX - rect.width * 0.02, y: rect.midY + dy),
                radius: rect.width * scale,
                startAngle: .degrees(-56),
                endAngle: .degrees(16),
                clockwise: false)
        }
        return path
    }
}
