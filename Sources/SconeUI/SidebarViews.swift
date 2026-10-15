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

struct SidebarSpotifyFooter: View {
    @Environment(SpotifyBridge.self) private var spotify
    var onConnect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {
            switch spotify.authorization {
            case .connected(let displayName):
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName.isEmpty ? "Connected" : displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)
                        Text("Powered by Spotify + Sonos")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(MidnightGlass.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isHovered {
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
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
                                .font(.caption.weight(.bold))
                                .foregroundStyle(MidnightGlass.primaryText)
                            Text("Sign in for track metadata & queue")
                                .font(.caption2)
                                .foregroundStyle(MidnightGlass.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MidnightGlass.gold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .midnightGlass(glowing: true, radius: 14)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

struct SconeHomeIcon: View {
    var highlighted: Bool = false
    var size: CGFloat = 28

    private var fill: Color {
        highlighted ? MidnightGlass.gold : MidnightGlass.primaryText.opacity(0.84)
    }

    var body: some View {
        ZStack {
            SconeMinimalHouseShape()
                .fill(fill)
                .frame(width: size * 0.58, height: size * 0.54)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SconeMinimalHouseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let roofPeakY = h * 0.04
        let eaveY = h * 0.46
        let bodyInsetX = w * 0.12
        let cornerR = w * 0.10

        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: roofPeakY))
        p.addLine(to: CGPoint(x: w, y: eaveY))
        p.addLine(to: CGPoint(x: w - bodyInsetX, y: eaveY))
        p.addLine(to: CGPoint(x: w - bodyInsetX, y: h - cornerR))
        p.addQuadCurve(
            to: CGPoint(x: w - bodyInsetX - cornerR, y: h),
            control: CGPoint(x: w - bodyInsetX, y: h)
        )
        p.addLine(to: CGPoint(x: bodyInsetX + cornerR, y: h))
        p.addQuadCurve(
            to: CGPoint(x: bodyInsetX, y: h - cornerR),
            control: CGPoint(x: bodyInsetX, y: h)
        )
        p.addLine(to: CGPoint(x: bodyInsetX, y: eaveY))
        p.addLine(to: CGPoint(x: 0, y: eaveY))
        p.closeSubpath()
        return p
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

    private var otherOnlineSpeakers: [Speaker] {
        let memberIDs = Set(group.speakers.map(\.id))
        return store.state.speakers.filter { $0.reachability.isOnline && !memberIDs.contains($0.id) }
    }

    var body: some View {
        row
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(MidnightGlass.gold, lineWidth: 1.5)
                }
            }
            .contextMenu {
                Button {
                    store.togglePlayOrHandOffSpotify(for: group)
                } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                }

                Button {
                    store.handOffSpotify(to: group.id)
                } label: {
                    Label("Play from Spotify", systemImage: "dot.radiowaves.left.and.right")
                }

                if !otherOnlineSpeakers.isEmpty {
                    Menu {
                        ForEach(otherOnlineSpeakers) { other in
                            let name = RoomNaming.shortName(other.roomName, merged: false)
                            Button("Group with \(name)") {
                                store.group(member: other.id, onto: group.coordinator.id)
                            }
                        }
                    } label: {
                        Label("Group with…", systemImage: "hifispeaker.2.fill")
                    }
                }

                if isMultiRoom {
                    Divider()
                    ForEach(group.speakers) { member in
                        let memberName = RoomNaming.shortName(member.roomName, merged: false)
                        Button(role: .destructive) {
                            store.ungroupSpeaker(member.id)
                        } label: {
                            Label("Remove \(memberName)", systemImage: "minus.circle")
                        }
                    }
                    Button(role: .destructive) {
                        store.dissolveGroup(group.id)
                    } label: {
                        Label("Ungroup All", systemImage: "xmark.circle")
                    }
                    Button {
                        store.savePreset(from: group.id)
                    } label: {
                        Label("Save as Preset", systemImage: "bookmark.fill")
                    }
                } else {
                    Divider()
                    let shortName = RoomNaming.shortName(group.coordinator.roomName, merged: false)
                    Button {
                        store.toggleMute(for: group.coordinator.id)
                    } label: {
                        Label(
                            group.coordinator.volume == .v0 ? "Unmute \(shortName)" : "Mute \(shortName)",
                            systemImage: group.coordinator.volume == .v0 ? "speaker.wave.2.fill" : "speaker.slash.fill"
                        )
                    }
                }
            }
    }

    @ViewBuilder private var row: some View {
        rowBody
            .dropDestination(for: String.self) { items, _ in
                joinedSpeaker(from: items, onto: group.coordinator.id, store: store)
            } isTargeted: { targeted = $0 }
            .draggable(group.coordinator.id.rawValue) { dragPreview(group.coordinator) }
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
                OfflinePill()
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
            OfflinePill()
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
