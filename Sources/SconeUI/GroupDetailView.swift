import DylDesign
import SconeDomain
import SconeStore
import SwiftUI

struct GroupDetailView: View {
    @Environment(SconeStore.self) private var store
    var group: SonosGroup

    private var ungroupedSpeakers: [Speaker] {
        let currentIDs = Set(group.speakers.map(\.id))
        return store.state.speakers.filter { $0.reachability.isOnline && !currentIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    Text(group.displayName)
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .foregroundStyle(MidnightGlass.primaryText)
                    Spacer()

                    if !ungroupedSpeakers.isEmpty {
                        Menu {
                            ForEach(ungroupedSpeakers) { candidate in
                                let name = RoomNaming.shortName(candidate.roomName, merged: false)
                                Button("Add \(name)") {
                                    store.group(member: candidate.id, onto: group.coordinator.id)
                                }
                            }
                        } label: {
                            Label("Add Room", systemImage: "plus.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(MidnightGlass.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(MidnightGlass.cardFill))
                                .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if group.speakers.count > 1 {
                        Button {
                            store.dissolveGroup(group.id)
                        } label: {
                            Label("Ungroup All", systemImage: "xmark.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(MidnightGlass.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(MidnightGlass.cardFill))
                                .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
                        }
                        .buttonStyle(PressableStyle())
                    }

                    if !playbackHasSession(group.playback) {
                        Button {
                            store.togglePlayOrHandOffSpotify(for: group)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text(store.state.externalSpotify != nil ? "Play here" : "Play")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(MidnightGlass.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(MidnightGlass.gold))
                            .shadow(color: MidnightGlass.gold.opacity(0.35), radius: 8)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }

                speakersSection
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if group.speakers.count > 1 {
                HStack(spacing: 14) {
                    Label("Group Volume", systemImage: "speaker.wave.3.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MidnightGlass.gold)
                    DiscreteVolumeControl(volume: group.volume) { volume in
                        store.send(.setVolume(volume, for: .group(group.id)))
                    }
                }
                Rectangle()
                    .fill(MidnightGlass.cardBorder.opacity(0.65))
                    .frame(height: 1)
            }

            VStack(spacing: 12) {
                ForEach(Array(group.speakers.enumerated()), id: \.element.id) { index, speaker in
                    if index > 0 {
                        Rectangle()
                            .fill(MidnightGlass.cardBorder.opacity(0.5))
                            .frame(height: 1)
                    }
                    SpeakerRowView(
                        speaker: speaker,
                        playing: playbackIsActive(group.playback),
                        canRemove: group.speakers.count > 1,
                        onRemove: { store.ungroupSpeaker(speaker.id) },
                        onVolume: { store.send(.setVolume($0, for: .speaker(speaker.id))) }
                    )
                    .contextMenu {
                        SpeakerGroupContextMenu(group: group, speaker: speaker)
                    }
                }
            }
        }
        .padding(16)
        .glassCard(radius: 18)
    }
}
