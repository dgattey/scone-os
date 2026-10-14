import SwiftUI
import SconeStore
import SconeUI
import SpotifyBridge
#if os(macOS)
import AppKit
#endif

@main
struct SconeOSApp: App {
    @State private var spotify: SpotifyBridge
    @State private var store: SconeStore

    init() {
        let clientID = ProcessInfo.processInfo.environment["SCONEOS_SPOTIFY_CLIENT_ID"] ?? ""
        let redirectURI = URL(string: "sconeos://spotify-callback")!
        let spotify = SpotifyBridge(clientID: clientID, redirectURI: redirectURI)
        _spotify = State(initialValue: spotify)
        _store = State(initialValue: SconeStore.live(spotify: spotify))
    }

    var body: some Scene {
        WindowGroup {
            root
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 840)
        .windowResizability(.contentMinSize)
        #endif
    }

    private var root: some View {
        let view = SconeRootView()
            .environment(store)
            .environment(spotify)
            .preferredColorScheme(.dark)
        #if os(macOS)
        return view
            .frame(minWidth: 1120, minHeight: 760)
            .onAppear {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        #else
        return view
        #endif
    }
}
