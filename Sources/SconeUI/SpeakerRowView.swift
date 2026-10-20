import DylDesign
import SconeDomain
import SconeStore
import SwiftUI

struct OfflineSpeakerDetail: View {
    @Environment(SconeStore.self) private var store
    var speaker: Speaker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text(RoomNaming.shortName(speaker.roomName, merged: false))
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .foregroundStyle(MidnightGlass.primaryText)
                    StatusPill("Offline")
                }
                SpeakerRowView(
                    speaker: speaker,
                    playing: false,
                    canRemove: false,
                    onRemove: {},
                    onVolume: { store.send(.setVolume($0, for: .speaker(speaker.id))) }
                )
                .padding(16)
                .glassCard(radius: 18)
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SpeakerRowView: View {
    var speaker: Speaker
    var playing: Bool
    var canRemove: Bool
    var onRemove: () -> Void
    var onVolume: (DiscreteVolume) -> Void

    @State private var isHovered = false

    private var roomTitle: String {
        RoomNaming.shortName(speaker.roomName, merged: false)
    }

    private var primaryModelName: String {
        speaker.model.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                SpeakerSilhouetteView(
                    model: speaker.model,
                    isOnline: speaker.reachability.isOnline,
                    isPlaying: playing,
                    isGrouped: canRemove,
                    size: 46
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(roomTitle)
                            .font(.headline)
                            .foregroundStyle(MidnightGlass.primaryText)
                            .lineLimit(1)
                        Text("· \(primaryModelName)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)
                        if let battery = speaker.model.battery {
                            SpeakerBatteryBadge(battery: battery)
                        }
                        if !speaker.reachability.isOnline {
                            StatusPill("Offline")
                        }
                        Spacer(minLength: 4)
                        if canRemove && isHovered {
                            Button(action: onRemove) {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Disconnect")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(Color.red.opacity(0.88))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                                .overlay(Capsule().strokeBorder(Color.red.opacity(0.28), lineWidth: 0.85))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                            .help("Disconnect \(roomTitle) from group")
                            .accessibilityLabel("Disconnect \(roomTitle)")
                        }
                    }
                    .frame(minHeight: 22)
                    DiscreteVolumeControl(volume: speaker.volume, onChange: onVolume)
                }
            }

            if !speaker.bondedSatellites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(speaker.bondedSatellites) { sat in
                        BondedSatelliteRow(
                            satellite: sat,
                            isPlaying: playing
                        )
                    }
                }
                .padding(.leading, 62)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(MidnightGlass.cardBorder.opacity(0.75))
                        .frame(width: 2)
                        .padding(.leading, 50)
                        .padding(.vertical, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

struct BondedSatelliteRow: View {
    var satellite: BondedSatellite
    var isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            SpeakerSilhouetteView(
                model: satellite.speakerModel,
                isOnline: satellite.isOnline,
                isPlaying: isPlaying,
                isGrouped: true,
                size: 22
            )
            HStack(spacing: 5) {
                Text(satellite.role.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MidnightGlass.primaryText)
                Text("· \(satellite.modelLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MidnightGlass.secondaryText)
            }
            Spacer(minLength: 8)
            if !satellite.isOnline {
                StatusPill("Offline")
            }
        }
        .padding(.vertical, 2)
    }
}
