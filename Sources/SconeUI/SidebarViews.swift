import DylDesign
import SwiftUI
import SconeDomain
import SconeStore
import SpotifyBridge

@MainActor
func joinedSpeaker(from items: [String], onto target: SpeakerUUID, store: SconeStore) -> Bool {
    guard let raw = items.first, let member = SpeakerUUID(rawValue: raw), member != target else { return false }
    store.group(member: member, onto: target)
    return true
}

struct SpeakerGroupContextMenu: View {
    @Environment(SconeStore.self) private var store
    var group: SonosGroup?
    var speaker: Speaker? = nil
    var isPinnedOnMap: Bool = false
    var onOpenGroup: ((GroupID) -> Void)? = nil

    private var excludedSpeakerIDs: Set<SpeakerUUID> {
        if let group {
            return Set(group.speakers.map(\.id))
        }
        if let speaker {
            return [speaker.id]
        }
        return []
    }

    private var otherOnlineSpeakers: [Speaker] {
        let excluded = excludedSpeakerIDs
        return store.state.speakers.filter { $0.reachability.isOnline && !excluded.contains($0.id) }
    }

    private var targetCoordinatorID: SpeakerUUID? {
        speaker?.id ?? group?.coordinator.id
    }

    var body: some View {
        if let group {
            let isPlaying = playbackIsActive(group.playback)
            Button {
                store.togglePlayOrHandOffSpotify(for: group)
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Button {
                store.handOffSpotify(to: group.id)
            } label: {
                Label("Play from Spotify", systemImage: "dot.radiowaves.left.and.right")
            }

            Divider()
        }

        if let targetCoordinatorID, !otherOnlineSpeakers.isEmpty {
            Menu {
                ForEach(otherOnlineSpeakers) { other in
                    let otherName = RoomNaming.shortName(other.roomName, merged: false)
                    Button("Group with \(otherName)") {
                        store.group(member: other.id, onto: targetCoordinatorID)
                    }
                }
                if store.state.speakers.filter(\.reachability.isOnline).count > 2 {
                    Divider()
                    Button("Group All Rooms (Everywhere)") {
                        store.groupEverywhere()
                    }
                }
            } label: {
                Label("Group with…", systemImage: "hifispeaker.2.fill")
            }
        }

        if let group, group.speakers.count > 1 {
            if let speaker {
                let shortName = RoomNaming.shortName(speaker.roomName, merged: false)
                Button(role: .destructive) {
                    store.ungroupSpeaker(speaker.id)
                } label: {
                    Label("Disconnect \(shortName)", systemImage: "xmark.circle")
                }
            } else {
                ForEach(group.speakers) { member in
                    let memberName = RoomNaming.shortName(member.roomName, merged: false)
                    Button(role: .destructive) {
                        store.ungroupSpeaker(member.id)
                    } label: {
                        Label("Disconnect \(memberName)", systemImage: "minus.circle")
                    }
                }
            }

            if speaker == nil || group.speakers.count > 2 {
                Button(role: .destructive) {
                    store.dissolveGroup(group.id)
                } label: {
                    Label("Ungroup All", systemImage: "xmark.circle")
                }
            }

            Button {
                store.savePreset(from: group.id)
            } label: {
                Label("Save as Preset", systemImage: "bookmark.fill")
            }
        }

        if let muteTarget = speaker ?? (group?.speakers.count == 1 ? group?.coordinator : nil) {
            let shortName = RoomNaming.shortName(muteTarget.roomName, merged: false)
            Divider()
            Button {
                store.toggleMute(for: muteTarget.id)
            } label: {
                Label(
                    muteTarget.volume == .v0 ? "Unmute \(shortName)" : "Mute \(shortName)",
                    systemImage: muteTarget.volume == .v0 ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
            }
        }

        if let speaker, isPinnedOnMap {
            Button {
                store.resetRoom(speaker.id)
            } label: {
                Label("Reset Map Position", systemImage: "arrow.counterclockwise")
            }
        }

        if let group, let onOpenGroup {
            Divider()
            Button {
                onOpenGroup(group.id)
            } label: {
                Label("Open \(group.displayName)", systemImage: "arrow.up.right.square")
            }
        }
    }
}

struct SpotifySidebarCard: View {
    @Environment(SpotifyBridge.self) private var spotify
    var inSidebarFooter: Bool = false
    var onConnect: () -> Void

    @State private var isHovered = false

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var body: some View {
        switch spotify.authorization {
        case .connected(let displayName):
            let resolvedName = displayName.isEmpty ? "Spotify" : displayName
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [MidnightGlass.gold, MidnightGlass.copper],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(initials(for: resolvedName))
                        .font(.system(size: inSidebarFooter ? 11 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(MidnightGlass.ink)
                }
                .frame(width: inSidebarFooter ? 28 : 34, height: inSidebarFooter ? 28 : 34)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(resolvedName)
                        .font((inSidebarFooter ? Font.footnote : Font.subheadline).weight(.semibold))
                        .foregroundStyle(MidnightGlass.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5.5, height: 5.5)
                        Text("Spotify Premium · Live")
                            .font(inSidebarFooter ? .system(size: 10.5, weight: .medium) : .caption)
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !inSidebarFooter || isHovered {
                    Button(role: .destructive) {
                        spotify.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.red.opacity(0.88))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.red.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.28), lineWidth: 0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, inSidebarFooter ? 10 : 0)
            .padding(.vertical, inSidebarFooter ? 7 : 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.18)) {
                    isHovered = hovering
                }
            }

        case .notConnected:
            Button(action: onConnect) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(MidnightGlass.gold)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect Spotify")
                            .font((inSidebarFooter ? Font.caption : Font.subheadline).weight(.bold))
                            .foregroundStyle(MidnightGlass.primaryText)
                        Text("Sign in for track metadata, artwork & live queue")
                            .font(.caption2)
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(inSidebarFooter ? 1 : 2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: inSidebarFooter ? 16 : 18, weight: .semibold))
                        .foregroundStyle(MidnightGlass.gold)
                }
                .padding(.horizontal, inSidebarFooter ? 12 : 4)
                .padding(.vertical, inSidebarFooter ? 10 : 6)
                .modifier(OptionalMidnightGlassModifier(enabled: inSidebarFooter))
            }
            .buttonStyle(PressableStyle())
        }
    }
}

private struct OptionalMidnightGlassModifier: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.glassCard(glowing: true, radius: 14)
        } else {
            content
        }
    }
}

struct SidebarIconWell: View {
    var systemName: String
    var highlighted: Bool = false
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.54, weight: .medium))
            .foregroundStyle(highlighted ? MidnightGlass.gold : MidnightGlass.primaryText.opacity(0.82))
            .frame(width: size, height: size)
    }
}

struct SidebarGroupRow: View {
    @Environment(SconeStore.self) private var store
    var group: SonosGroup
    var isSelected: Bool = false
    @State private var targeted = false

    private var isMultiRoom: Bool { group.speakers.count > 1 }
    private var playing: Bool { playbackIsActive(group.playback) }
    private var hasSession: Bool {
        playbackHasSession(group.playback) && !isSuppressedPausedDuplicate(group, in: store.state.groups)
    }

    var body: some View {
        rowBody
            .dropDestination(for: String.self) { items, _ in
                joinedSpeaker(from: items, onto: group.coordinator.id, store: store)
            } isTargeted: { targeted = $0 }
            .draggable(group.coordinator.id.rawValue) { dragPreview(group.coordinator) }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(MidnightGlass.gold, lineWidth: 1.5)
                }
            }
            .contextMenu {
                SpeakerGroupContextMenu(group: group)
            }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isMultiRoom {
                    SidebarIconWell(systemName: "speaker.wave.3.fill", highlighted: true, size: 32)
                } else {
                    SpeakerSilhouetteView(
                        model: group.coordinator.model,
                        isOnline: group.coordinator.reachability.isOnline,
                        isPlaying: playing || isSelected,
                        size: 32
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                        .font(.body.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? MidnightGlass.gold : MidnightGlass.primaryText)
                        .lineLimit(1)
                    if hasSession, case .track(let track) = group.playback.nowPlaying, !track.title.isEmpty {
                        Text(track.artist.map { "\(track.title) · \($0)" } ?? track.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(playing ? MidnightGlass.gold : MidnightGlass.secondaryText)
                            .lineLimit(1)
                    } else if !isMultiRoom, !group.coordinator.bondedSatellites.isEmpty {
                        Text("+ \(group.coordinator.bondedSatellites.count) surrounds")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                    }
                }
                Spacer(minLength: 4)
                if !isMultiRoom, let battery = group.coordinator.model.battery {
                    SpeakerBatteryBadge(battery: battery)
                }
                if hasSession {
                    if case .track(let track) = group.playback.nowPlaying, track.artworkURL != nil {
                        AlbumArtworkView(url: track.artworkURL, size: 22, cornerRadius: 5)
                    } else if playing {
                        PlayingMark()
                    }
                }
            }
            if isMultiRoom {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.speakers) { speaker in
                        SidebarMemberRow(
                            speaker: speaker,
                            playing: playing,
                            onRemove: { store.ungroupSpeaker(speaker.id) }
                        )
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(MidnightGlass.gold.opacity(0.45))
                        .frame(width: 2)
                        .padding(.leading, 15)
                        .padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct SidebarMemberRow: View {
    var speaker: Speaker
    var playing: Bool
    var onRemove: () -> Void

    @State private var isHovered = false

    private var shortName: String {
        RoomNaming.shortName(speaker.roomName, merged: false)
    }

    var body: some View {
        HStack(spacing: 8) {
            SpeakerSilhouetteView(
                model: speaker.model,
                isOnline: speaker.reachability.isOnline,
                isPlaying: playing,
                isGrouped: true,
                size: 26
            )
            Text(shortName)
                .font(.subheadline)
                .foregroundStyle(MidnightGlass.primaryText.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let battery = speaker.model.battery {
                SpeakerBatteryBadge(battery: battery)
            }
            if !speaker.reachability.isOnline {
                StatusPill("Offline")
            }
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.88))
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(Color.red.opacity(0.14)))
                }
                .buttonStyle(.borderless)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .help("Disconnect \(shortName)")
                .accessibilityLabel("Disconnect \(shortName)")
            }
        }
        .frame(minHeight: 22)
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .draggable(speaker.id.rawValue) { dragPreview(speaker) }
    }
}

struct SidebarOfflineRow: View {
    var speaker: Speaker

    var body: some View {
        HStack(spacing: 10) {
            SpeakerSilhouetteView(model: speaker.model, isOnline: false, size: 32)
            Text(RoomNaming.shortName(speaker.roomName, merged: false))
                .font(.body.weight(.medium))
                .foregroundStyle(MidnightGlass.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            StatusPill("Offline")
        }
        .padding(.vertical, 3)
        .opacity(0.65)
        .contentShape(Rectangle())
    }
}

func dragPreview(_ speaker: Speaker) -> some View {
    Text(RoomNaming.shortName(speaker.roomName, merged: false))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(MidnightGlass.gold)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(MidnightGlass.cardElevatedFill))
        .overlay(Capsule().strokeBorder(MidnightGlass.gold.opacity(0.75), lineWidth: 1))
}
