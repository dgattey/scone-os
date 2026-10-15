import SwiftUI
import SconeDomain
import SconeStore

struct NowPlayingDock: View {
    @Environment(SconeStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var group: SonosGroup
    var eligibleGroups: [SonosGroup]
    var onSelectDockGroup: (GroupID) -> Void
    var onOpen: () -> Void

    @State private var showingQueuePopover = LaunchView.requestsQueuePopover()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ViewThatFits(in: .horizontal) {
                wideLayout
                compactLayout
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .midnightGlass(glowing: true, radius: 18)

            if showingQueuePopover, case .track(let track) = group.playback.nowPlaying {
                DockQueuePopoverView(
                    group: group,
                    track: track,
                    onSelectQueueItem: { item in
                        showingQueuePopover = false
                        store.playQueueItem(item, on: group.id)
                    },
                    onClose: { showingQueuePopover = false }
                )
                .frame(width: 390)
                .padding(14)
                .midnightGlass(glowing: true, radius: 18)
                .shadow(color: Color.black.opacity(0.45), radius: 22, y: 8)
                .offset(y: -74)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                .zIndex(50)
            }
        }
        .animation(.snappy(duration: 0.2), value: showingQueuePopover)
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
                let target: VolumeTarget = group.speakers.count > 1
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
                let target: VolumeTarget = group.speakers.count > 1
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
        if case .track = group.playback.nowPlaying {
            Button {
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

    private var artworkURL: URL? {
        if case .track(let track) = group.playback.nowPlaying {
            return track.artworkURL
        }
        return nil
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
            return group.displayName
        case .tvAudio, .stream:
            return group.displayName
        case nil:
            return "\(group.speakers.count) rooms grouped · Ready to play"
        }
    }

    private var sourceLine: String? {
        guard case .track(let track) = group.playback.nowPlaying,
              let source = track.source else {
            return nil
        }
        return source.label
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
                .foregroundStyle(enabled ? (prominent ? MidnightGlass.ink : MidnightGlass.primaryText) : MidnightGlass.secondaryText.opacity(0.35))
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
