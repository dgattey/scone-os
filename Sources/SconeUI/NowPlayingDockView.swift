import DylDesign
import SconeDomain
import SconeStore
import SwiftUI

struct NowPlayingDock: View {
    @Environment(SconeStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var group: SonosGroup
    var eligibleGroups: [SonosGroup]
    var onSelectDockGroup: (GroupID) -> Void
    var onOpen: () -> Void

    @State private var showingQueuePopover = LaunchView.requestsQueuePopover()
    @State private var showingVolumePopover = false

    private var isCompactFloatingPill: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact || LaunchView.requestsIOS()
        #else
        return LaunchView.requestsIOS()
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isCompactFloatingPill {
                spotifyFloatingPill
            } else {
                ViewThatFits(in: .horizontal) {
                    wideLayout
                    compactLayout
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCard(glowing: true, radius: 18)
            }

            if showingVolumePopover && isCompactFloatingPill {
                floatingVolumeCard
                    .offset(y: -66)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .zIndex(55)
            }

            if showingQueuePopover, let track = effectiveQueueTrack {
                DockQueuePopoverView(
                    group: group,
                    track: track,
                    onSelectQueueItem: { item in
                        showingQueuePopover = false
                        store.playQueueItem(item, on: group.id)
                    },
                    onClose: { showingQueuePopover = false }
                )
                .frame(maxWidth: isCompactFloatingPill ? .infinity : 390)
                .padding(14)
                .glassCard(glowing: true, radius: 18)
                .shadow(color: Color.black.opacity(0.55), radius: 24, y: 10)
                .offset(y: isCompactFloatingPill ? -66 : -74)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                .zIndex(50)
            }
        }
        .animation(.snappy(duration: 0.2), value: showingQueuePopover)
        .animation(.snappy(duration: 0.2), value: showingVolumePopover)
    }

    private var spotifyFloatingPill: some View {
        HStack(spacing: 11) {
            Button(action: onOpen) {
                HStack(spacing: 11) {
                    AlbumArtworkView(url: artworkURL, size: 42, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MidnightGlass.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: "hifispeaker.fill")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(MidnightGlass.gold)
                            Text(floatingPillSubtitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(MidnightGlass.gold)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button {
                    showingQueuePopover = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        showingVolumePopover.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: group.volume == .v0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(group.volume.percent)%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(showingVolumePopover ? MidnightGlass.ink : MidnightGlass.gold)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        Capsule().fill(showingVolumePopover ? MidnightGlass.gold : MidnightGlass.subtleFill)
                    )
                    .overlay(
                        Capsule().strokeBorder(MidnightGlass.gold.opacity(0.45), lineWidth: 1)
                    )
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Volume \(group.volume.percent) percent")

                queuePopoverButton

                if externalSpotify != nil {
                    playHereButton(height: 28, horizontalPadding: 10, fontSize: 11.5)
                } else {
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
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(MidnightGlass.cardElevatedFill)
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        let ratio = CGFloat(group.volume.percent) / 100.0
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                                .frame(height: 2)
                            Capsule()
                                .fill(MidnightGlass.gold.opacity(0.88))
                                .frame(width: max(6, (geo.size.width - 28) * ratio), height: 2)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 1.5)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            MidnightGlass.gold.opacity(0.65),
                            MidnightGlass.cardBorder.opacity(0.85),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
        }
        .shadow(color: Color.black.opacity(0.55), radius: 18, x: 0, y: 8)
        .shadow(color: MidnightGlass.copper.opacity(0.22), radius: 10, x: 0, y: 3)
    }

    private var floatingVolumeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(group.displayName, systemImage: "hifispeaker.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MidnightGlass.gold)
                Spacer()
                Button {
                    showingVolumePopover = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MidnightGlass.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(MidnightGlass.subtleFill))
                }
                .buttonStyle(.plain)
            }
            DiscreteVolumeControl(volume: group.volume, compact: true) { volume in
                let target: VolumeTarget =
                    group.speakers.count > 1
                    ? .group(group.id)
                    : .speaker(group.coordinator.id)
                store.send(.setVolume(volume, for: target))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(glowing: true, radius: 16)
        .shadow(color: Color.black.opacity(0.50), radius: 20, y: 8)
    }

    private var floatingPillSubtitle: String {
        switch group.playback.nowPlaying {
        case .track(let track):
            if let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
                return "\(group.displayName) · \(artist)"
            }
            return group.displayName
        case .tvAudio, .stream:
            return group.displayName
        case nil:
            if let external = externalSpotify {
                let artist = external.metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty {
                    return "\(artist) · \(external.externalPlaybackLabel)"
                }
                return "\(external.externalPlaybackLabel) · \(group.displayName)"
            }
            if group.speakers.count > 1 {
                return "\(group.speakers.count) rooms grouped"
            }
            return "\(group.coordinator.model.displayName) · Ready to play"
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 14) {
            titleCluster
            if eligibleGroups.count > 1 {
                groupSwitcherMenu
            }
            Spacer(minLength: 10)
            transportButtons
            DiscreteVolumeControl(volume: group.volume, compact: true) { volume in
                let target: VolumeTarget =
                    group.speakers.count > 1
                    ? .group(group.id)
                    : .speaker(group.coordinator.id)
                store.send(.setVolume(volume, for: target))
            }
            .frame(width: 210)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                titleCluster
                Spacer(minLength: 4)
                if eligibleGroups.count > 1 {
                    groupSwitcherMenu
                }
                transportButtons
            }
            DiscreteVolumeControl(volume: group.volume, compact: true) { volume in
                let target: VolumeTarget =
                    group.speakers.count > 1
                    ? .group(group.id)
                    : .speaker(group.coordinator.id)
                store.send(.setVolume(volume, for: target))
            }
        }
    }

    private var titleCluster: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                AlbumArtworkView(url: artworkURL, size: 46, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MidnightGlass.primaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(MidnightGlass.gold)
                            .lineLimit(1)
                    }
                    if let sourceLine {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(sourceLine)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(MidnightGlass.secondaryText)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var queuePopoverButton: some View {
        if effectiveQueueTrack != nil {
            Button {
                showingVolumePopover = false
                let willShow = !showingQueuePopover
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    showingQueuePopover = willShow
                }
                if willShow {
                    store.refreshSpotifyQueueIfNeeded()
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(showingQueuePopover ? MidnightGlass.gold : MidnightGlass.primaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(
                            showingQueuePopover
                                ? MidnightGlass.gold.opacity(0.18)
                                : MidnightGlass.subtleFill
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(
                            showingQueuePopover ? MidnightGlass.gold.opacity(0.65) : MidnightGlass.cardBorder,
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(PressableStyle())
            .help("Up Next Queue")
            .accessibilityLabel("Up Next Queue")
        }
    }

    private var groupSwitcherMenu: some View {
        Menu {
            ForEach(eligibleGroups) { candidate in
                Button {
                    onSelectDockGroup(candidate.id)
                } label: {
                    HStack {
                        Text(candidate.displayName)
                        if candidate.id == group.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(eligibleGroups.count) Groups")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(MidnightGlass.gold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(MidnightGlass.subtleFill))
            .overlay(Capsule().strokeBorder(MidnightGlass.gold.opacity(0.45), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var transportButtons: some View {
        HStack(spacing: 8) {
            queuePopoverButton
            if externalSpotify != nil {
                playHereButton(height: 34, horizontalPadding: 13, fontSize: 12.5)
            } else {
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
            if group.speakers.count > 1 {
                Button {
                    store.dissolveGroup(group.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MidnightGlass.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(MidnightGlass.subtleFill))
                        .overlay(Circle().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .help("Ungroup \(group.displayName)")
                .accessibilityLabel("Ungroup \(group.displayName)")
            }
        }
    }

    private func playHereButton(height: CGFloat, horizontalPadding: CGFloat, fontSize: CGFloat) -> some View {
        Button {
            store.togglePlayOrHandOffSpotify(for: group)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: fontSize - 1.5, weight: .bold))
                Text("Play here")
                    .font(.system(size: fontSize, weight: .semibold))
            }
            .foregroundStyle(MidnightGlass.ink)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(MidnightGlass.gold))
        }
        .buttonStyle(PressableStyle())
        .help("Play on \(group.displayName)")
        .accessibilityLabel("Play on \(group.displayName)")
    }

    private var externalSpotify: SpotifyTrackContext? {
        guard group.playback.nowPlaying == nil else { return nil }
        return store.state.externalSpotify
    }

    private var effectiveQueueTrack: NowPlayingTrack? {
        if case .track(let track) = group.playback.nowPlaying {
            return track
        }
        if let external = externalSpotify {
            return NowPlayingTrack(
                title: external.metadata.title,
                artist: external.metadata.artist.isEmpty ? nil : external.metadata.artist,
                album: external.metadata.album,
                artworkURL: external.metadata.artworkURL,
                duration: external.metadata.duration,
                queuePosition: nil,
                spotifyURI: external.uri,
                source: .spotify(contextTitle: external.contextTitle),
                upNext: external.upNext,
                canSkip: true
            )
        }
        return nil
    }

    private var artworkURL: URL? {
        if case .track(let track) = group.playback.nowPlaying {
            return track.artworkURL
        }
        return externalSpotify?.metadata.artworkURL
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
            if let externalTitle = externalSpotify?.metadata.title, !externalTitle.isEmpty {
                externalTitle
            } else {
                group.displayName
            }
        }
    }

    private var subtitle: String? {
        switch group.playback.nowPlaying {
        case .track(let track):
            if let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
                return "\(artist) · \(group.displayName)"
            }
            return group.displayName
        case .tvAudio, .stream:
            return group.displayName
        case nil:
            if let external = externalSpotify {
                let artist = external.metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty {
                    return "\(artist) · \(group.displayName)"
                }
                return group.displayName
            }
            if group.speakers.count > 1 {
                return "\(group.speakers.count) rooms grouped · Ready to play"
            }
            return "\(group.coordinator.model.displayName) · Ready to play"
        }
    }

    private var sourceLine: String? {
        if case .track(let track) = group.playback.nowPlaying,
            let source = track.source
        {
            return source.label
        }
        if let external = externalSpotify {
            if let ctxTitle = external.contextTitle, !ctxTitle.isEmpty {
                return "\(external.externalPlaybackLabel) · \(ctxTitle)"
            }
            return external.externalPlaybackLabel
        }
        return nil
    }

    private var canSkip: Bool {
        guard case .track(let track) = group.playback.nowPlaying else { return false }
        return track.canSkip
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
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(
                    enabled
                        ? (prominent ? MidnightGlass.ink : MidnightGlass.primaryText)
                        : MidnightGlass.secondaryText.opacity(0.35)
                )
                .frame(width: prominent ? 34 : 28, height: prominent ? 34 : 28)
                .background {
                    if prominent {
                        Circle().fill(MidnightGlass.gold)
                    } else {
                        Circle().fill(MidnightGlass.subtleFill)
                    }
                }
                .overlay(Circle().strokeBorder(prominent ? Color.clear : MidnightGlass.cardBorder, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

struct DockQueuePopoverView: View {
    var group: SonosGroup
    var track: NowPlayingTrack
    var onSelectQueueItem: (QueueItem) -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AlbumArtworkView(url: track.artworkURL, size: 40, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    if let source = track.source {
                        Text(source.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MidnightGlass.gold)
                            .lineLimit(1)
                    }
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MidnightGlass.primaryText)
                        .lineLimit(1)
                    if let artist = track.artist, !artist.isEmpty {
                        Text("\(artist) · \(group.displayName)")
                            .font(.caption)
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(MidnightGlass.subtleFill))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            Rectangle()
                .fill(MidnightGlass.cardBorder)
                .frame(height: 1)

            UpNextQueueCard(
                track: track,
                roomName: group.displayName,
                maxHeight: 300,
                embedded: true,
                onSelectQueueItem: onSelectQueueItem
            )
        }
    }
}
