#if os(macOS)
import Combine
import OSLog
@preconcurrency import Sparkle
import SwiftUI

private let sparkleLogger = Logger(subsystem: "com.sconeos.Sconeos", category: "Sparkle")

/// While Sparkle is showing update UI or installing, do not quit when its window closes.
@MainActor
final class SparkleUpdateSession {
    static let shared = SparkleUpdateSession()

    private var nesting = 0

    var blocksQuitOnLastWindowClosed: Bool { nesting > 0 }

    func begin() {
        nesting += 1
    }

    func end() {
        nesting = max(0, nesting - 1)
    }

    func reset() {
        nesting = 0
    }
}

@MainActor
final class SparkleStandardUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            SparkleUpdateSession.shared.begin()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            SparkleUpdateSession.shared.reset()
        }
    }
}

/// Presents Sparkle's update UI when the launch-time probe finds a newer build.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var launchProbeActive = false

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            guard self.launchProbeActive else { return }
            self.launchProbeActive = false
            updater.checkForUpdates()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.launchProbeActive = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in
            SparkleUpdateSession.shared.reset()
            sparkleLogger.error("Sparkle update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            SparkleUpdateSession.shared.begin()
            sparkleLogger.info("Installing update \(version, privacy: .public)")
        }
    }
}

@MainActor
final class AppUpdaterModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    private let isReleaseConfigured: Bool
    private var didCheckOnLaunch = false
    private var didScheduleLaunchCheck = false
    private let sparkleDelegate = SparkleUpdaterDelegate()
    private let sparkleUserDriverDelegate = SparkleStandardUserDriverDelegate()
    private var launchCheckCancellable: AnyCancellable?

    init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = !(feedURL?.isEmpty ?? true) && !(publicKey?.isEmpty ?? true)
        isReleaseConfigured = configured

        // Start the updater only when release metadata is present so local/dev builds avoid Sparkle config errors.
        controller = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: sparkleDelegate,
            userDriverDelegate: sparkleUserDriverDelegate
        )
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Call once the SwiftUI main window is on screen so a launch probe cannot close the last window and quit.
    func mainWindowDidAppear() {
        guard isReleaseConfigured, !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true

        if controller.updater.canCheckForUpdates {
            checkForUpdatesOnLaunch()
        } else {
            launchCheckCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
                .removeDuplicates()
                .filter { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.checkForUpdatesOnLaunch()
                }
        }
    }

    /// Probes the feed once per launch; Sparkle shows the update dialog only when a newer build exists.
    func checkForUpdatesOnLaunch() {
        guard isReleaseConfigured, !didCheckOnLaunch else { return }
        didCheckOnLaunch = true
        sparkleDelegate.launchProbeActive = true
        controller.updater.checkForUpdateInformation()
    }
}

struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: AppUpdaterModel

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#endif
