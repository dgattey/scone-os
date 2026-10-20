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
    weak var updater: SPUUpdater?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            SparkleUpdateSession.shared.begin()
            if !handleShowingUpdate {
                updater?.checkForUpdates()
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            SparkleUpdateSession.shared.reset()
        }
    }
}

@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            sparkleLogger.info("Sparkle found valid update \(version, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        let isNoUpdate = nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            SparkleUpdateSession.shared.reset()
            if isNoUpdate {
                sparkleLogger.info("Sparkle update check finished: \(message, privacy: .public)")
            } else {
                sparkleLogger.error("Sparkle update check failed: \(message, privacy: .public)")
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
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
    private var canCheckCancellable: AnyCancellable?

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
        sparkleUserDriverDelegate.updater = controller.updater
        canCheckCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Call once the SwiftUI main window is on screen so a launch check cannot close the last window and quit.
    func mainWindowDidAppear() {
        guard isReleaseConfigured, !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true

        // If Sparkle's scheduler already started a due check during startup, let that session run.
        guard !controller.updater.sessionInProgress else {
            didCheckOnLaunch = true
            return
        }

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

    /// Checks the feed in the background once per launch; Sparkle shows the update dialog only when a newer build exists.
    func checkForUpdatesOnLaunch() {
        guard isReleaseConfigured, !didCheckOnLaunch else { return }
        didCheckOnLaunch = true
        guard !controller.updater.sessionInProgress else { return }
        controller.updater.checkForUpdatesInBackground()
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
