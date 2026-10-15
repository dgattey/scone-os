import AuthenticationServices
import SwiftUI
import SconeDomain
import SconeStore
import SpotifyBridge
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

func playbackIsActive(_ playback: PlaybackState) -> Bool {
    if case .playing = playback { true } else { false }
}

func playbackHasSession(_ playback: PlaybackState) -> Bool {
    switch playback {
    case .playing, .paused:
        return true
    case .stopped:
        return false
    }
}

func playbackStreamKey(_ nowPlaying: NowPlaying?) -> String? {
    guard let nowPlaying else { return nil }
    switch nowPlaying {
    case .track(let track):
        if let uri = track.spotifyURI?.description.lowercased(), !uri.isEmpty {
            return "uri:\(uri)"
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !title.isEmpty {
            return "track:\(title)|\(artist)"
        }
        if let source = track.source, source.isSpotify {
            return "spotify:context"
        }
        return nil
    case .stream(let title):
        let norm = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "stream:\(norm)"
    case .tvAudio:
        return nil
    }
}

func isSuppressedPausedDuplicate(_ group: SonosGroup, in allGroups: [SonosGroup]) -> Bool {
    guard case .paused(let pausedNP, _) = group.playback else { return false }
    let playingGroups = allGroups.filter { $0.id != group.id && playbackIsActive($0.playback) }
    guard !playingGroups.isEmpty else { return false }

    if let pausedKey = playbackStreamKey(pausedNP) {
        if playingGroups.contains(where: { playbackStreamKey($0.playback.nowPlaying) == pausedKey }) {
            return true
        }
    }
    if case .track(let pausedTrack) = pausedNP,
       (pausedTrack.source?.isSpotify == true || pausedTrack.spotifyURI != nil) {
        if playingGroups.contains(where: {
            if case .track(let activeTrack) = $0.playback.nowPlaying {
                return activeTrack.source?.isSpotify == true || activeTrack.spotifyURI != nil
            }
            return false
        }) {
            return true
        }
    }
    return false
}

func deduplicatedActiveHubGroups(from groups: [SonosGroup]) -> [SonosGroup] {
    let candidates = groups.filter { group in
        if group.speakers.count > 1 { return true }
        guard playbackHasSession(group.playback) else { return false }
        return !isSuppressedPausedDuplicate(group, in: groups)
    }

    var seenKeys = Set<String>()
    var seenSpotifyAccount = false
    var result: [SonosGroup] = []

    let prioritized = candidates.sorted { lhs, rhs in
        let lPlay = playbackIsActive(lhs.playback)
        let rPlay = playbackIsActive(rhs.playback)
        if lPlay != rPlay { return lPlay && !rPlay }
        if lhs.speakers.count != rhs.speakers.count { return lhs.speakers.count > rhs.speakers.count }
        return lhs.id < rhs.id
    }

    for group in prioritized {
        if let key = playbackStreamKey(group.playback.nowPlaying) {
            if seenKeys.contains(key) {
                if group.speakers.count <= 1 {
                    continue
                }
            } else {
                seenKeys.insert(key)
            }
        }
        if case .track(let track) = group.playback.nowPlaying,
           (track.source?.isSpotify == true || track.spotifyURI != nil) {
            if seenSpotifyAccount && !playbackIsActive(group.playback) && group.speakers.count <= 1 {
                continue
            }
            seenSpotifyAccount = true
        }
        result.append(group)
    }

    let keptIDs = Set(result.map(\.id))
    return groups.filter { keptIDs.contains($0.id) }
}

public enum LaunchView {
    public static func requestsGroup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_INITIAL_VIEW"]?.lowercased() == "group" { return true }
        if arguments.contains(where: { $0.lowercased() == "--initial-view=group" }) { return true }
        guard let index = arguments.firstIndex(of: "--initial-view"),
              arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1].lowercased() == "group"
    }

    public static func requestsLivingRoom(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_INITIAL_VIEW"]?.lowercased() == "living" { return true }
        if arguments.contains(where: { $0.lowercased() == "--initial-view=living" }) { return true }
        return false
    }

    public static func requestsGuestRoom(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_INITIAL_VIEW"]?.lowercased() == "guest" { return true }
        if arguments.contains(where: { $0.lowercased() == "--initial-view=guest" }) { return true }
        return false
    }

    public static func requestsQueuePopover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_SHOW_QUEUE"] == "1" { return true }
        if arguments.contains(where: { $0.lowercased() == "--show-queue" }) { return true }
        return false
    }

    public static func requestsIOS(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["SCONEOS_LAYOUT"]?.lowercased() == "ios" { return true }
        if arguments.contains(where: { $0.lowercased() == "--layout=ios" }) { return true }
        return false
    }

    public static func requestedCompactTab(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        if let tab = environment["SCONEOS_COMPACT_TAB"]?.lowercased(), !tab.isEmpty {
            return tab
        }
        for arg in arguments {
            let lowered = arg.lowercased()
            if lowered.hasPrefix("--tab=") {
                return String(lowered.dropFirst("--tab=".count))
            }
        }
        return nil
    }

    public static func requestedColorScheme(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> ColorScheme? {
        let env = environment["SCONEOS_APPEARANCE"]?.lowercased()
        if env == "light" { return .light }
        if env == "dark" { return .dark }
        for arg in arguments {
            let lowered = arg.lowercased()
            if lowered == "--appearance=light" { return .light }
            if lowered == "--appearance=dark" { return .dark }
        }
        if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            let next = arguments[index + 1].lowercased()
            if next == "light" { return .light }
            if next == "dark" { return .dark }
        }
        return nil
    }
}

enum SidebarDestination: Hashable {
    case home
    case group(GroupID)
    case speaker(SpeakerUUID)
}

private enum AppTab: Hashable {
    case map
    case rooms
    case settings
}

public struct SconeRootView: View {
    @Environment(SconeStore.self) private var store
    @Environment(SpotifyBridge.self) private var spotify
    @Environment(\.webAuthenticationSession) private var webAuthSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: SidebarDestination? = .home
    @State private var activeTab: AppTab = .map
    @State private var mapPath: [GroupID] = []
    @State private var roomsPath: [GroupID] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var appliedLaunch = false
    @State private var dockSelectedGroupID: GroupID?

    public init() {}

    private var dockEligibleGroups: [SonosGroup] {
        deduplicatedActiveHubGroups(from: store.state.groups)
    }

    private var activeDockGroup: SonosGroup? {
        if case .group(let viewedID) = selection,
           let viewedGroup = store.state.groups.first(where: { $0.id == viewedID }),
           (playbackIsActive(viewedGroup.playback)
            || (playbackHasSession(viewedGroup.playback) && !isSuppressedPausedDuplicate(viewedGroup, in: store.state.groups))
            || viewedGroup.speakers.count > 1) {
            return viewedGroup
        }
        let eligible = dockEligibleGroups
        guard !eligible.isEmpty else { return nil }
        if let dockSelectedGroupID, let matched = eligible.first(where: { $0.id == dockSelectedGroupID }) {
            return matched
        }
        if let playing = eligible.first(where: { playbackIsActive($0.playback) }) {
            return playing
        }
        if let pausedWithTrack = eligible.first(where: { playbackHasSession($0.playback) }) {
            return pausedWithTrack
        }
        return eligible.first
    }

    private var isCompactLayout: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact || LaunchView.requestsIOS()
        #else
        return LaunchView.requestsIOS()
        #endif
    }

    public var body: some View {
        Group {
            if isCompactLayout {
                tabRoot
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
                .hideWindowToolbarBackground()
            }
        }
        .tint(MidnightGlass.gold)
        .optionalPreferredColorScheme(LaunchView.requestedColorScheme())
        .overlay(alignment: .topTrailing) {
            if let alert = store.state.alert {
                AlertBanner(
                    message: alertMessage(alert),
                    actionTitle: isNotConnectedAlert(alert) ? "Connect Spotify" : nil,
                    onAction: isNotConnectedAlert(alert) ? {
                        store.dismissAlert()
                        triggerSpotifyConnect()
                    } : nil,
                    dismiss: { store.dismissAlert() }
                )
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

    private var tabRoot: some View {
        TabView(selection: $activeTab) {
            NavigationStack(path: $mapPath) {
                ZStack {
                    MidnightBackground()
                    HomePane(
                        showInlinePresets: true,
                        onSelectGroup: { groupID in
                            selection = .group(groupID)
                            mapPath = [groupID]
                        }
                    )
                }
                .navigationDestination(for: GroupID.self) { groupID in
                    ZStack {
                        MidnightBackground()
                        if let group = store.state.groups.first(where: { $0.id == groupID }) {
                            GroupDetailView(group: group)
                        }
                    }
                    .navigationTitle(
                        store.state.groups.first(where: { $0.id == groupID })?.displayName ?? "Room"
                    )
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    sharedCompactToolbar(title: store.state.networkName ?? "Sconeos")
                }
                .safeAreaInset(edge: .bottom) {
                    sharedBottomDock { groupID in
                        selection = .group(groupID)
                        mapPath = [groupID]
                    }
                }
            }
            .tabItem {
                Label("Home Map", systemImage: "map.fill")
            }
            .tag(AppTab.map)

            NavigationStack(path: $roomsPath) {
                ZStack {
                    MidnightBackground()
                    List {
                        Section {
                            ForEach(store.state.groups) { group in
                                let isSelected = (selection == .group(group.id))
                                Button {
                                    selection = .group(group.id)
                                    roomsPath = [group.id]
                                } label: {
                                    SidebarGroupRow(group: group, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                .listRowBackground(MidnightGlass.cardFill)
                            }
                        } header: {
                            Text("Active Rooms")
                        }

                        if !offlineSpeakers.isEmpty {
                            Section {
                                ForEach(offlineSpeakers) { speaker in
                                    SidebarOfflineRow(speaker: speaker)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                        .listRowBackground(MidnightGlass.cardFill)
                                }
                            } header: {
                                Text("Offline")
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
                .navigationDestination(for: GroupID.self) { groupID in
                    ZStack {
                        MidnightBackground()
                        if let group = store.state.groups.first(where: { $0.id == groupID }) {
                            GroupDetailView(group: group)
                        }
                    }
                    .navigationTitle(
                        store.state.groups.first(where: { $0.id == groupID })?.displayName ?? "Room"
                    )
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    sharedCompactToolbar(title: "Rooms")
                }
                .safeAreaInset(edge: .bottom) {
                    sharedBottomDock { groupID in
                        selection = .group(groupID)
                        roomsPath = [groupID]
                    }
                }
            }
            .tabItem {
                Label("Rooms", systemImage: "hifispeaker.2.fill")
            }
            .tag(AppTab.rooms)

            NavigationStack {
                ZStack {
                    MidnightBackground()
                    SconeSettingsView(onConnectSpotify: triggerSpotifyConnect)
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    sharedCompactToolbar(title: "Settings")
                }
                .safeAreaInset(edge: .bottom) {
                    sharedBottomDock { groupID in
                        selection = .group(groupID)
                        activeTab = .map
                        mapPath = [groupID]
                    }
                }
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(AppTab.settings)
        }
    }

    @ToolbarContentBuilder
    private func sharedCompactToolbar(title: String) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                SconeBrandEmblem(size: 26)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MidnightGlass.primaryText)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Text(store.state.speakerCountSummary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MidnightGlass.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(MidnightGlass.cardFill))
                .overlay(Capsule().strokeBorder(MidnightGlass.cardBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func sharedBottomDock(onOpenGroup: @escaping (GroupID) -> Void) -> some View {
        if let group = activeDockGroup {
            NowPlayingDock(
                group: group,
                eligibleGroups: dockEligibleGroups,
                onSelectDockGroup: {
                    dockSelectedGroupID = $0
                    if case .group = selection {
                        selection = .group($0)
                    }
                },
                onOpen: {
                    onOpenGroup(group.id)
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func triggerSpotifyConnect() {
        Task {
            try? await spotify.connect(using: webAuthSession)
        }
    }

    private func isNotConnectedAlert(_ alert: SconeAlert) -> Bool {
        if case .spotify(.notConnected) = alert { return true }
        return false
    }

    private var sidebarBrandHeaderRow: some View {
        let isHomeSelected = (selection == .home || selection == nil)
        return HStack(spacing: 10) {
            SconeBrandEmblem(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                if let net = store.state.networkName, !net.isEmpty {
                    Text(net)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isHomeSelected ? MidnightGlass.gold : MidnightGlass.primaryText)
                        .lineLimit(1)
                }
                if store.state.totalSpeakerCount > 0 {
                    Text(store.state.speakerCountSummary)
                        .font(.caption2)
                        .foregroundStyle(MidnightGlass.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var sidebar: some View {
        List {
            let isHomeSelected = (selection == .home || selection == nil)
            sidebarBrandHeaderRow
                .onTapGesture {
                    selection = .home
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(sidebarRowBackground(selected: isHomeSelected))

            ForEach(store.state.groups) { group in
                let isSelected = (selection == .group(group.id))
                SidebarGroupRow(group: group, isSelected: isSelected)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = .group(group.id)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(sidebarRowBackground(selected: isSelected))
            }

            ForEach(offlineSpeakers) { speaker in
                SidebarOfflineRow(speaker: speaker)
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            SidebarSpotifyFooter(onConnect: triggerSpotifyConnect)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func sidebarRowBackground(selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(MidnightGlass.gold.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(MidnightGlass.gold.opacity(0.45), lineWidth: 1)
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var detail: some View {
        let isShowingHome: Bool = switch selection {
        case .home, nil:
            true
        case .group(let id):
            !store.state.groups.contains(where: { $0.id == id })
        case .speaker(let id):
            !store.state.speakers.contains(where: { $0.id == id })
        }

        ZStack {
            MidnightBackground()
            Group {
                switch selection {
                case .home, nil:
                    HomePane(
                        onSelectGroup: { groupID in
                            selection = .group(groupID)
                        }
                    )
                case .group(let id):
                    if let group = store.state.groups.first(where: { $0.id == id }) {
                        GroupDetailView(group: group)
                    } else {
                        HomePane(
                            onSelectGroup: { groupID in
                                selection = .group(groupID)
                            }
                        )
                    }
                case .speaker(let id):
                    if let speaker = store.state.speakers.first(where: { $0.id == id }) {
                        OfflineSpeakerDetail(speaker: speaker)
                    } else {
                        HomePane(
                            onSelectGroup: { groupID in
                                selection = .group(groupID)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if let group = activeDockGroup {
                NowPlayingDock(
                    group: group,
                    eligibleGroups: dockEligibleGroups,
                    onSelectDockGroup: {
                        dockSelectedGroupID = $0
                        if case .group = selection {
                            selection = .group($0)
                        }
                    },
                    onOpen: {
                        selection = .group(group.id)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .toolbar {
            if isShowingHome {
                if #available(macOS 26.0, iOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        PresetPillsBar(inToolbar: true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        PresetPillsBar(inToolbar: true)
                    }
                }
            }
        }
        .hideWindowToolbarBackground()
    }

    private var offlineSpeakers: [Speaker] {
        let grouped = Set(store.state.groups.flatMap { $0.speakers.map(\.id) })
        return store.state.speakers.filter { !$0.reachability.isOnline && !grouped.contains($0.id) }
    }

    private func applyLaunchSelection() {
        if !appliedLaunch, let tab = LaunchView.requestedCompactTab() {
            switch tab {
            case "rooms":
                activeTab = .rooms
            case "settings", "spotify":
                activeTab = .settings
            default:
                activeTab = .map
            }
        }
        guard !appliedLaunch else { return }
        if LaunchView.requestsGuestRoom() {
            if let guestGroup = store.state.groups.first(where: {
                $0.speakers.contains { $0.roomName.lowercased().contains("guest") }
            }) ?? store.state.groups.first(where: { $0.playback.nowPlaying != nil }) {
                selection = .group(guestGroup.id)
                if isCompactLayout { mapPath = [guestGroup.id] }
                appliedLaunch = true
            }
            return
        }
        if LaunchView.requestsLivingRoom() {
            if let livingGroup = store.state.groups.first(where: {
                $0.speakers.contains { $0.roomName.lowercased().contains("living") || !$0.bondedSatellites.isEmpty }
            }) {
                selection = .group(livingGroup.id)
                if isCompactLayout { mapPath = [livingGroup.id] }
                appliedLaunch = true
            }
            return
        }
        guard LaunchView.requestsGroup() else { return }
        if let bondedGroup = store.state.groups.first(where: {
            $0.speakers.contains { !$0.bondedSatellites.isEmpty }
        }) {
            selection = .group(bondedGroup.id)
            if isCompactLayout { mapPath = [bondedGroup.id] }
            appliedLaunch = true
            return
        }
        let multi = store.state.groups.filter { $0.speakers.count > 1 }
        if let count = multi.map(\.speakers.count).max(),
           let group = multi.first(where: { $0.speakers.count == count }) {
            selection = .group(group.id)
            if isCompactLayout { mapPath = [group.id] }
            appliedLaunch = true
        } else if let first = store.state.groups.first {
            selection = .group(first.id)
            if isCompactLayout { mapPath = [first.id] }
            appliedLaunch = true
        }
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
                "Nothing is playing on Spotify"
            case .unplayableOnSonos:
                "That track cannot play here"
            case .authorizationFailed(let detail):
                detail.isEmpty ? "Spotify did not connect" : detail
            case .network:
                "The network did not answer"
            }
        case .quarantined:
            "A saved file could not be read"
        }
    }
}

private extension View {
    @ViewBuilder
    func optionalPreferredColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            self.preferredColorScheme(scheme)
        } else {
            self
        }
    }

    @ViewBuilder
    func hideWindowToolbarBackground() -> some View {
        #if os(macOS)
        self.toolbarBackground(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }
}

private struct HomePane: View {
    var showInlinePresets: Bool = false
    var onSelectGroup: (GroupID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showInlinePresets {
                PresetPillsBar(inToolbar: false)
                    .padding(.top, 8)
            }
            FloorplanMapView(onSelectGroup: onSelectGroup)
        }
    }
}

struct SconeSettingsView: View {
    @Environment(SconeStore.self) private var store
    @Environment(SpotifyBridge.self) private var spotify
    var onConnectSpotify: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    SconeBrandEmblem(size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sconeos")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(MidnightGlass.primaryText)
                        Text(store.state.networkAndSpeakerSummary)
                            .font(.subheadline)
                            .foregroundStyle(MidnightGlass.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(MidnightGlass.cardFill)
            }

            Section {
                switch spotify.authorization {
                case .connected(let displayName):
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName.isEmpty ? "Connected to Spotify" : displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(MidnightGlass.primaryText)
                            Text("Track metadata, album artwork, queue & Sonos handoff")
                                .font(.caption)
                                .foregroundStyle(MidnightGlass.secondaryText)
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive) {
                            spotify.disconnect()
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(MidnightGlass.cardFill)

                case .notConnected:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(MidnightGlass.gold)
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spotify Account")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(MidnightGlass.primaryText)
                                Text("Sign in for track metadata, album artwork, live queue & one-tap Sonos handoff.")
                                    .font(.caption)
                                    .foregroundStyle(MidnightGlass.secondaryText)
                            }
                        }
                        Button(action: onConnectSpotify) {
                            HStack {
                                Text("Connect Spotify")
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                Image(systemName: "arrow.up.right.circle.fill")
                                    .font(.body.weight(.semibold))
                            }
                            .foregroundStyle(MidnightGlass.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(MidnightGlass.gold)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(MidnightGlass.cardFill)
                }
            } header: {
                Text("Spotify")
            }

            Section {
                ForEach(store.state.speakers) { speaker in
                    HStack(spacing: 12) {
                        SpeakerSilhouetteView(
                            model: speaker.model,
                            isOnline: speaker.reachability.isOnline,
                            isPlaying: false,
                            size: 32
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RoomNaming.shortName(speaker.roomName, merged: false))
                                .font(.body.weight(.medium))
                                .foregroundStyle(MidnightGlass.primaryText)
                            if !speaker.bondedSatellites.isEmpty {
                                Text("\(speaker.model.displayName) + \(speaker.bondedSatellites.count) surrounds")
                                    .font(.caption)
                                    .foregroundStyle(MidnightGlass.secondaryText)
                            } else {
                                Text(speaker.model.displayName)
                                    .font(.caption)
                                    .foregroundStyle(MidnightGlass.secondaryText)
                            }
                        }
                        Spacer()
                        if let battery = speaker.model.battery {
                            SpeakerBatteryBadge(battery: battery)
                        }
                        if !speaker.reachability.isOnline {
                            OfflinePill()
                        } else {
                            Text("\(speaker.volume.percent)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(MidnightGlass.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(MidnightGlass.cardFill)
                }
            } header: {
                Text("Sonos Household (\(store.state.speakerCountSummary))")
            }

            Section {
                HStack {
                    Text("Version")
                        .foregroundStyle(MidnightGlass.primaryText)
                    Spacer()
                    Text("0.1.0")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(MidnightGlass.secondaryText)
                }
                .listRowBackground(MidnightGlass.cardFill)
            } header: {
                Text("About")
            }
        }
        .scrollContentBackground(.hidden)
    }
}

private struct AlertBanner: View {
    var message: String
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(MidnightGlass.gold)
                .frame(width: 6, height: 6)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(MidnightGlass.primaryText)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MidnightGlass.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MidnightGlass.gold))
                    .buttonStyle(.plain)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MidnightGlass.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .midnightGlass(glowing: true, radius: 16)
    }
}
