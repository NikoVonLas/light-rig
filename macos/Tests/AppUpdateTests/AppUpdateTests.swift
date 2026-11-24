#if CANON_RIG_UPDATES
import Sparkle
import XCTest
@testable import CanonRig

@MainActor
final class AppUpdateTests: XCTestCase {
    func testSparkleRecognizesUpdateGuards() {
        let updates = AppUpdates { false }
        for selector in [
            #selector(SPUUpdaterDelegate.updater(_:mayPerform:)),
            #selector(SPUUpdaterDelegate.updater(_:shouldProceedWithUpdate:updateCheck:)),
            #selector(SPUUpdaterDelegate.updater(_:willExtractUpdate:)),
            #selector(SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)),
            #selector(SPUUpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)),
            #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))
        ] {
            XCTAssertTrue(updates.responds(to: selector), NSStringFromSelector(selector))
        }
    }

    func testActiveCameraBlocksManualAndBackgroundChecksIncludingAfterDiscovery() throws {
        var busy = true
        let updates = AppUpdates { busy }
        let updater = updates.updater
        let item = SUAppcastItem.empty()
        for kind in [SPUUpdateCheck.updates, .updatesInBackground] {
            XCTAssertThrowsError(try updates.updater(updater, mayPerform: kind))
            XCTAssertThrowsError(try updates.updater(updater, shouldProceedWithUpdate: item, updateCheck: kind))
        }
        busy = false
        try updates.updater(updater, mayPerform: .updates)
        try updates.updater(updater, shouldProceedWithUpdate: item, updateCheck: .updates)
    }

    func testCallStartingAfterDownloadDefersRelaunchExactlyOnce() {
        var busy = false
        let updates = AppUpdates { busy }
        var installs = 0
        let item = SUAppcastItem.empty()
        updates.updater(updates.updater, willExtractUpdate: item)
        busy = true
        XCTAssertTrue(updates.updater(updates.updater, shouldPostponeRelaunchForUpdate: item) { installs += 1 })
        updates.resumeWhenIdle()
        XCTAssertEqual(installs, 0)
        busy = false
        updates.resumeWhenIdle()
        updates.resumeWhenIdle()
        XCTAssertEqual(installs, 1)
    }

    func testOnlyPendingInstallDelaysQuitDuringCall() {
        var busy = true
        let updates = AppUpdates { busy }
        let updater = updates.updater
        let item = SUAppcastItem.empty()
        XCTAssertFalse(updates.shouldWaitToQuit())
        updates.updater(updater, willExtractUpdate: item)
        XCTAssertTrue(updates.shouldWaitToQuit())
        XCTAssertFalse(updates.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {}))
        updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        XCTAssertTrue(updates.shouldWaitToQuit())
        busy = false
        XCTAssertFalse(updates.shouldWaitToQuit())
    }
}
#endif
