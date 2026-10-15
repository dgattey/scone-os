import SwiftUI
import SconeDomain
import SconeStore

struct PresetPillsBar: View {
    var inToolbar: Bool = false
    @Environment(SconeStore.self) private var store
    @State private var creating = false
    @State private var renaming: PresetID?
    @State private var renameText = ""

    private var activeMultiGroups: [SonosGroup] {
        store.state.groups.filter { $0.speakers.count > 1 }
    }

    private var isEverywhereActive: Bool {
        let onlineCount = store.state.speakers.filter(\.reachability.isOnline).count
        guard onlineCount > 1, store.state.groups.count == 1 else { return false }
        return store.state.groups[0].speakers.count == onlineCount
    }

    var body: some View {
        if inToolbar {
            pillsRow
                .alert(
                    "Rename Preset",
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
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                pillsRow
            }
            .alert(
                "Rename Preset",
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

    private var pillsRow: some View {
        HStack(spacing: 6) {
            if store.state.speakers.filter(\.reachability.isOnline).count > 1 {
                Button {
                    if isEverywhereActive, let group = store.state.groups.first {
                        store.dissolveGroup(group.id)
                    } else {
                        store.groupEverywhere()
                    }
                } label: {
                    PresetPillLabel(
                        title: "Everywhere",
                        systemImage: "house.fill",
                        active: isEverywhereActive,
                        compact: inToolbar
                    )
                }
                .buttonStyle(PressableStyle())
                .focusEffectDisabled()
                .contextMenu {
                    Button {
                        store.groupEverywhere()
                    } label: {
                        Label("Group All Rooms", systemImage: "hifispeaker.2.fill")
                    }
                    if isEverywhereActive, let group = store.state.groups.first {
                        Button(role: .destructive) {
                            store.dissolveGroup(group.id)
                        } label: {
                            Label("Ungroup All", systemImage: "xmark.circle")
                        }
                    }
                }
            }

            ForEach(store.state.presets) { preset in
                Button {
                    store.applyPreset(preset)
                } label: {
                    PresetPillLabel(
                        title: preset.name,
                        active: store.state.isActive(preset),
                        compact: inToolbar
                    )
                }
                .buttonStyle(PressableStyle())
                .focusEffectDisabled()
                .contextMenu {
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        Label("Apply", systemImage: "play.circle")
                    }

                    Button {
                        renameText = preset.name
                        renaming = preset.id
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }

                    if activeMultiGroups.count == 1, let currentGroup = activeMultiGroups.first {
                        Button {
                            store.updatePreset(preset.id, from: currentGroup.id)
                        } label: {
                            Label("Update with Current Grouping", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else if activeMultiGroups.count > 1 {
                        Menu {
                            ForEach(activeMultiGroups) { group in
                                Button(group.displayName) {
                                    store.updatePreset(preset.id, from: group.id)
                                }
                            }
                        } label: {
                            Label("Update with Current Grouping", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        store.deletePreset(preset.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                creating = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    if store.state.presets.isEmpty {
                        Text("New Preset")
                            .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(MidnightGlass.gold)
                .padding(.horizontal, store.state.presets.isEmpty ? 11 : 9)
                .frame(height: inToolbar ? 28 : 32)
                .background(Capsule().fill(MidnightGlass.cardFill))
                .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .focusEffectDisabled()
            .accessibilityLabel("Add preset")
            .popover(isPresented: $creating, arrowEdge: .bottom) {
                PresetCreator(onDismiss: { creating = false })
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 380)
            }
        }
        .fixedSize(horizontal: inToolbar, vertical: false)
        .padding(.horizontal, inToolbar ? 4 : 20)
        .padding(.vertical, inToolbar ? 2 : 8)
    }
}

private struct PresetPillLabel: View {
    var title: String
    var systemImage: String? = nil
    var active: Bool
    var compact: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
            }
            Text(title)
                .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(active ? MidnightGlass.ink : MidnightGlass.primaryText)
        .padding(.horizontal, compact ? 11 : 14)
        .frame(height: compact ? 28 : 32)
        .background {
            Capsule().fill(isHovered && !active ? MidnightGlass.cardElevatedFill : MidnightGlass.cardFill)
            if active {
                Capsule().fill(
                    LinearGradient(
                        colors: [MidnightGlass.gold, MidnightGlass.copper],
                        startPoint: .top,
                        endPoint: .bottom))
            }
        }
        .overlay {
            Capsule().strokeBorder(
                active
                    ? MidnightGlass.gold
                    : (isHovered ? MidnightGlass.gold.opacity(0.48) : MidnightGlass.cardBorder),
                lineWidth: 1
            )
        }
        .shadow(color: active ? MidnightGlass.copper.opacity(0.35) : Color.black.opacity(0.05), radius: 6, y: 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.snappy(duration: 0.18), value: active)
        .animation(.snappy(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
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
                                        .foregroundStyle(MidnightGlass.primaryText)
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
                                        .fill(MidnightGlass.subtleFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().overlay(MidnightGlass.cardBorder)
                }
                TextField("Preset Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .foregroundStyle(MidnightGlass.primaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(MidnightGlass.subtleFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
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
                    Text("Save Preset")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(canCreate ? MidnightGlass.ink : MidnightGlass.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(canCreate ? MidnightGlass.gold : MidnightGlass.subtleFill))
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
                    .foregroundStyle(lead ? MidnightGlass.gold : MidnightGlass.secondaryText)
                Text(RoomNaming.shortName(speaker.roomName, merged: false))
                    .foregroundStyle(MidnightGlass.primaryText)
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
