import DylShell
import DylUpdates
import SwiftUI
import SconeDomain
import SconeStore
import SconeUI
import SpotifyBridge
#if os(macOS)
import AppKit

@MainActor
final class SconeAppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockIcon(for: NSApp.effectiveAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            Task { @MainActor in
                self?.updateDockIcon(for: app.effectiveAppearance)
            }
        }
    }

    func updateDockIcon(for appearance: NSAppearance?) {
        let resolved = appearance ?? NSApp.effectiveAppearance
        let isDark = resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resourceName = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    /// Sparkle closes its alert when installing; without this, a single-window app can quit before download/install runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        QuitBlockers.shared.shouldTerminateAfterLastWindowClosed
    }
}
#endif

@main
struct SconeosApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SconeAppDelegate.self) private var appDelegate
    @StateObject private var updater = AppUpdater()
    #endif
    @State private var session: LiveSession?

    init() {
        LaunchShell.configure(LaunchView.overrides)
    }

    var body: some Scene {
        WindowGroup("Sconeos") {
            root
        }
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(
            width: LaunchView.requestsIOS() ? 402 : 1280,
            height: LaunchView.requestsIOS() ? 874 : 840
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    if let target = primaryTargetGroup {
                        store?.togglePlayOrHandOffSpotify(for: target)
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Track") {
                    if let target = primaryTargetGroup {
                        store?.send(.nextTrack(group: target.id))
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Track") {
                    if let target = primaryTargetGroup {
                        store?.send(.previousTrack(group: target.id))
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("Volume Up") {
                    if let target = primaryTargetGroup {
                        let next = target.volume.stepped(by: 1)
                        let volumeTarget: VolumeTarget = target.speakers.count > 1
                            ? .group(target.id)
                            : .speaker(target.coordinator.id)
                        store?.send(.setVolume(next, for: volumeTarget))
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Volume Down") {
                    if let target = primaryTargetGroup {
                        let next = target.volume.stepped(by: -1)
                        let volumeTarget: VolumeTarget = target.speakers.count > 1
                            ? .group(target.id)
                            : .speaker(target.coordinator.id)
                        store?.send(.setVolume(next, for: volumeTarget))
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Divider()

                Button("Group All Rooms (Everywhere)") {
                    store?.groupEverywhere()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
        #endif
    }

    private var store: SconeStore? { session?.store }

    private var primaryTargetGroup: SonosGroup? {
        guard let groups = store?.state.groups else { return nil }
        if let playing = groups.first(where: {
            if case .playing = $0.playback { return true }
            return false
        }) {
            return playing
        }
        if let multi = groups.first(where: { $0.speakers.count > 1 }) {
            return multi
        }
        return groups.first
    }

    private var root: some View {
        let requestedScheme = LaunchView.requestedColorScheme()
        let isIOSPreview = LaunchView.requestsIOS()
        let view = sessionContent
            .preferredColorScheme(requestedScheme)
            .task { session = await LiveSession.shared.value }
        #if os(macOS)
        return view
            .frame(
                minWidth: isIOSPreview ? 402 : 980,
                idealWidth: isIOSPreview ? 402 : 1280,
                maxWidth: isIOSPreview ? 430 : .infinity,
                minHeight: isIOSPreview ? 850 : 660,
                idealHeight: isIOSPreview ? 874 : 840
            )
            .onAppear {
                updater.mainWindowDidAppear()
                LaunchShell.applyAppearance(LaunchView.overrides.appearance)
            }
            .launchWindowSize(LaunchView.overrides)
        #else
        return view
        #endif
    }

    @ViewBuilder private var sessionContent: some View {
        if let session {
            SconeRootView()
                .environment(session.store)
                .environment(session.spotify)
        } else {
            Color.clear
        }
    }
}
