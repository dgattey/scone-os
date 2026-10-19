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
    private lazy var darkDockIcon = Self.renderDarkBundleIcon()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            Task { @MainActor in
                self?.updateDockIcon(for: app.effectiveAppearance)
            }
        }
    }

    /// Icon style Default keeps the closed Dock tile light even in Dark UI. Every other style and light UI keep
    /// the bundle icon (nil), so the running tile only diverges from the closed one when the app is dark.
    private func updateDockIcon(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let usesDefaultIconStyle = UserDefaults.standard.object(forKey: "AppleIconAppearanceTheme") == nil
        NSApp.applicationIconImage = isDark && usesDefaultIconStyle ? darkDockIcon : nil
    }

    /// Renders the compiled Icon Composer asset through the IconServices resource that draws the closed tile, so mask,
    /// glass and shadow match it. No public API selects the dark iconstack while icon style is Default.
    private static func renderDarkBundleIcon() -> NSImage? {
        typealias MakeResource = @convention(c) (AnyObject, Selector, NSURL, NSString, UnsafeMutableRawPointer?) -> AnyObject?
        typealias SetAppearance = @convention(c) (AnyObject, Selector, Int) -> Void
        typealias ImageForSize = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> AnyObject?
        typealias GetCGImage = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        let makeResource = NSSelectorFromString("assetCatalogResourceWithURL:imageName:error:")
        let setAppearance = NSSelectorFromString("setAppearance:")
        let imageForSize = NSSelectorFromString("imageForSize:scale:")
        let getCGImage = NSSelectorFromString("CGImage")
        guard #available(macOS 26, *),
              let resourceClass = NSClassFromString("ISAssetCatalogResource") as AnyObject?,
              resourceClass.responds(to: makeResource),
              let catalogURL = Bundle.main.url(forResource: "Assets", withExtension: "car"),
              let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
              let resource = unsafeBitCast(resourceClass.method(for: makeResource), to: MakeResource.self)(
                  resourceClass, makeResource, catalogURL as NSURL, iconName as NSString, nil
              ),
              resource.responds(to: setAppearance),
              resource.responds(to: imageForSize)
        else { return nil }
        let darkAppearance = 1
        unsafeBitCast(resource.method(for: setAppearance), to: SetAppearance.self)(resource, setAppearance, darkAppearance)
        let points = CGSize(width: 512, height: 512)
        guard let image = unsafeBitCast(resource.method(for: imageForSize), to: ImageForSize.self)(resource, imageForSize, points, 2),
              image.responds(to: getCGImage),
              let cgImage = unsafeBitCast(image.method(for: getCGImage), to: GetCGImage.self)(image, getCGImage)?.takeUnretainedValue()
        else { return nil }
        return NSImage(cgImage: cgImage, size: points)
    }

    /// Sparkle closes its alert when installing; without this, a single-window app can quit before download/install runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SparkleUpdateSession.shared.blocksQuitOnLastWindowClosed
    }
}
#endif

@main
struct SconeosApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SconeAppDelegate.self) private var appDelegate
    @StateObject private var updater = AppUpdaterModel()
    #endif
    @State private var spotify: SpotifyBridge
    @State private var store: SconeStore

    init() {
        let redirectURI = URL(string: "sconeos://spotify-callback")!
        let spotify = SpotifyBridge(redirectURI: redirectURI)
        _spotify = State(initialValue: spotify)
        _store = State(initialValue: SconeStore.live(spotify: spotify))
        #if os(macOS)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        if let scheme = LaunchView.requestedColorScheme() {
            NSApplication.shared.appearance = NSAppearance(
                named: scheme == .dark ? .darkAqua : .aqua
            )
        }
        #endif
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
                CheckForUpdatesMenuItem(updater: updater)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    if let target = primaryTargetGroup {
                        store.togglePlayOrHandOffSpotify(for: target)
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Track") {
                    if let target = primaryTargetGroup {
                        store.send(.nextTrack(group: target.id))
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Track") {
                    if let target = primaryTargetGroup {
                        store.send(.previousTrack(group: target.id))
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
                        store.send(.setVolume(next, for: volumeTarget))
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Volume Down") {
                    if let target = primaryTargetGroup {
                        let next = target.volume.stepped(by: -1)
                        let volumeTarget: VolumeTarget = target.speakers.count > 1
                            ? .group(target.id)
                            : .speaker(target.coordinator.id)
                        store.send(.setVolume(next, for: volumeTarget))
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Divider()

                Button("Group All Rooms (Everywhere)") {
                    store.groupEverywhere()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
        #endif
    }

    private var primaryTargetGroup: SonosGroup? {
        if let playing = store.state.groups.first(where: {
            if case .playing = $0.playback { return true }
            return false
        }) {
            return playing
        }
        if let multi = store.state.groups.first(where: { $0.speakers.count > 1 }) {
            return multi
        }
        return store.state.groups.first
    }

    private var root: some View {
        let requestedScheme = LaunchView.requestedColorScheme()
        let isIOSPreview = LaunchView.requestsIOS()
        let view = SconeRootView()
            .environment(store)
            .environment(spotify)
            .preferredColorScheme(requestedScheme)
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
                if let scheme = requestedScheme {
                    NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                }
                if let rawSize = ProcessInfo.processInfo.environment["SCONEOS_WINDOW_SIZE"] {
                    let parts = rawSize.split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 {
                        let targetSize = NSSize(width: parts[0], height: parts[1])
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            for window in NSApp.windows where window.frame.width > 300 {
                                window.setContentSize(targetSize)
                            }
                        }
                    }
                }
            }
        #else
        return view
        #endif
    }
}
