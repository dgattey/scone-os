import SwiftUI
import SconeDomain
import SconeStore

struct PresetPillsBar: View {
    @Environment(SconeStore.self) private var store
    @State private var creating = false
    @State private var renaming: PresetID?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.state.presets) { preset in
                    Button {
                        store.send(.applyPreset(preset))
                    } label: {
                        PresetPillLabel(title: preset.name, active: store.state.isActive(preset))
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        Button("Rename") {
                            renameText = preset.name
                            renaming = preset.id
                        }
                        Button("Delete", role: .destructive) {
                            store.deletePreset(preset.id)
                        }
                    }
                }
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MidnightGlass.gold)
                        .frame(width: 36, height: 32)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Add preset")
                .popover(isPresented: $creating, arrowEdge: .bottom) {
                    PresetCreator(onDismiss: { creating = false })
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 380)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming {
                    store.renamePreset(renaming, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct PresetPillLabel: View {
    var title: String
    var active: Bool

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? MidnightGlass.ink : Color.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(.ultraThinMaterial)
                if active {
                    Capsule().fill(
                        LinearGradient(
                            colors: [MidnightGlass.gold, MidnightGlass.copper],
                            startPoint: .top,
                            endPoint: .bottom))
                }
            }
            .overlay {
                Capsule().strokeBorder(active ? MidnightGlass.gold : Color.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: active ? MidnightGlass.copper.opacity(0.65) : .clear, radius: 10)
    }
}

private struct PresetCreator: View {
    @Environment(SconeStore.self) private var store
    var onDismiss: () -> Void
    @State private var draftName = ""
    @State private var picked: [SpeakerUUID] = []

    private var multiRoom: [SonosGroup] {
        store.state.groups.filter { $0.speakers.count > 1 }
    }

    private var canCreate: Bool {
        picked.count >= 2 && !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !multiRoom.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(multiRoom) { group in
                            Button {
                                store.savePreset(from: group.id)
                                onDismiss()
                            } label: {
                                HStack {
                                    Text(group.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("Save")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(MidnightGlass.ink)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(MidnightGlass.gold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.12))
                }
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                VStack(spacing: 6) {
                    ForEach(store.state.speakers) { speaker in
                        roomRow(speaker)
                    }
                }
                Button {
                    guard let coordinator = picked.first else { return }
                    store.createPreset(
                        name: draftName,
                        coordinator: coordinator,
                        members: Set(picked.dropFirst()))
                    onDismiss()
                } label: {
                    Text("Save")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(canCreate ? MidnightGlass.ink : Color.white.opacity(0.38))
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(canCreate ? MidnightGlass.gold : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(maxHeight: 480)
        .presentationBackground(.ultraThinMaterial)
    }

    private func roomRow(_ speaker: Speaker) -> some View {
        let on = picked.contains(speaker.id)
        let lead = picked.first == speaker.id
        return Button {
            toggle(speaker.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(lead ? MidnightGlass.gold : Color.white.opacity(0.72))
                Text(RoomNaming.shortName(speaker.roomName, merged: false))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !speaker.reachability.isOnline {
                    OfflinePill()
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: SpeakerUUID) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }
}
