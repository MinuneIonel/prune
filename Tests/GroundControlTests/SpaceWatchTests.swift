import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// Menu bar / alerts (M4). Free space and the clock are injected; notifications and the login item are
/// fakes, so nothing here asks macOS for permission or registers anything.
@MainActor
@Suite("Space watch")
struct SpaceWatchTests {
    nonisolated static let GB: Int64 = 1_000_000_000

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @MainActor
    final class Harness {
        let world: FixtureWorld
        let free = Box<Int64?>(30 * SpaceWatchTests.GB)
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let notifier: RecordingNotifier
        let loginItem = InMemoryLoginItem()
        let state = InMemoryAlertState()
        let model: GroundControlModel

        init(authorization: NotificationAuthorization = .notDetermined, grant: Bool = true) throws {
            world = try FixtureWorld.create(scale: 0.01)
            notifier = RecordingNotifier(authorization: authorization, grantOnRequest: grant)
            var env = AppEnvironment.fixture(world)
            env.fullDiskAccess = { .granted }
            model = GroundControlModel(environment: env)
        }
        deinit { world.destroy() }

        func watch() -> SpaceWatch {
            let free = self.free, clock = self.clock
            return SpaceWatch(model: model, dependencies: .init(freeSpace: { free.value }, now: { clock.value },
                                                                 notifier: notifier, loginItem: loginItem, state: state))
        }

        func setFree(_ gb: Double) { free.value = Int64(gb * Double(SpaceWatchTests.GB)) }
    }

    // MARK: Policy

    @Test func policyAlertsOncePerCrossingAndRearmsWithMargin() {
        let t = 20 * Self.GB
        #expect(LowSpacePolicy.rearmMargin(threshold: t) == 2 * Self.GB)
        #expect(LowSpacePolicy.rearmMargin(threshold: 100 * Self.GB) == 10 * Self.GB)
        var alerted = false
        var posts = 0
        // GB readings: above, cross, stay below, hover just above, dip again, recover past margin, cross again.
        for gb in [25.0, 19, 13, 12, 20.5, 19.5, 21.9, 18, 22.1, 30, 19] {
            let r = LowSpacePolicy.evaluate(free: Int64(gb * 1e9), threshold: t, alerted: alerted, enabled: true)
            if r.notify { posts += 1 }
            alerted = r.alerted
        }
        #expect(posts == 2)
    }

    @Test func policyDisabledNeverNotifiesNorUsesUpTheCrossing() {
        let t = 20 * Self.GB
        let r = LowSpacePolicy.evaluate(free: 5 * Self.GB, threshold: t, alerted: false, enabled: false)
        #expect(!r.notify && !r.alerted)
        // Turning it on later while still low alerts once.
        let r2 = LowSpacePolicy.evaluate(free: 5 * Self.GB, threshold: t, alerted: r.alerted, enabled: true)
        #expect(r2.notify && r2.alerted)
        // A crossing already alerted re-arms even while notifications are off.
        let r3 = LowSpacePolicy.evaluate(free: 30 * Self.GB, threshold: t, alerted: true, enabled: false)
        #expect(!r3.notify && !r3.alerted)
    }

    // MARK: Watcher

    @Test func defaultsAreOffAndTouchNothing() async throws {
        let h = try Harness()
        #expect(!h.model.settings.lowSpaceNotifications)
        #expect(!h.model.settings.launchAtLogin)
        #expect(!h.model.settings.weeklyRescan)
        #expect(h.model.settings.lowSpaceThresholdGB == 20)
        let w = h.watch()
        h.setFree(3)
        await w.check()
        await w.check()
        #expect(w.isBelowThreshold)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.requestCount == 0)       // never prompts on its own
        #expect(h.loginItem.current == .disabled)   // never registers on its own
        #expect(!h.state.lowSpaceAlerted)
        #expect(!h.model.isScanning)                // the check never scans
        #expect(!h.model.hasScanned)
    }

    @Test func notifiesOncePerCrossingThroughTheWatcher() async throws {
        let h = try Harness()
        let w = h.watch()
        await w.setNotificationsEnabled(true)
        #expect(h.notifier.requestCount == 1)
        #expect(h.model.settings.lowSpaceNotifications)
        #expect(h.world.settingsStore.load().lowSpaceNotifications)

        for gb in [30.0, 19, 12, 3, 20.5, 19, 21.5] {
            h.setFree(gb)
            await w.check()
        }
        #expect(h.notifier.posted.count == 1)
        #expect(h.notifier.posted.first?.freeBytes == 19 * Self.GB)
        #expect(h.notifier.posted.first?.thresholdBytes == 20 * Self.GB)
        #expect(h.state.lowSpaceAlerted)

        h.setFree(23); await w.check()   // recovered past threshold + 2 GB margin: re-armed
        #expect(!h.state.lowSpaceAlerted)
        h.setFree(10); await w.check()
        #expect(h.notifier.posted.count == 2)

        // Turning it back on doesn't prompt again.
        await w.setNotificationsEnabled(false)
        await w.setNotificationsEnabled(true)
        #expect(h.notifier.requestCount == 1)
    }

    @Test func alertStateSurvivesRelaunch() async throws {
        let h = try Harness(authorization: .authorized)
        h.model.updateSettings { $0.lowSpaceNotifications = true }
        h.setFree(5)
        await h.watch().check()
        #expect(h.notifier.posted.count == 1)
        // A new watcher (app relaunch / launch at login) with the same persisted state stays quiet.
        await h.watch().check()
        #expect(h.notifier.posted.count == 1)
    }

    @Test func deniedPermissionKeepsTheOptionOff() async throws {
        let h = try Harness(grant: false)
        let w = h.watch()
        await w.setNotificationsEnabled(true)
        #expect(w.notificationAuthorization == .denied)
        #expect(!h.model.settings.lowSpaceNotifications)
        h.setFree(1)
        await w.check()
        #expect(h.notifier.posted.isEmpty)
    }

    @Test func revokedPermissionStopsPosting() async throws {
        let h = try Harness(authorization: .authorized)
        h.model.updateSettings { $0.lowSpaceNotifications = true }
        h.notifier.currentAuthorization = .denied
        h.setFree(1)
        await h.watch().check()
        #expect(h.notifier.posted.isEmpty)
        #expect(!h.state.lowSpaceAlerted)
    }

    @Test func thresholdIsConfigurableAndRechecked() async throws {
        let h = try Harness(authorization: .authorized)
        h.model.updateSettings { $0.lowSpaceNotifications = true }
        let w = h.watch()
        h.setFree(15)
        await w.setThresholdGB(10)
        #expect(h.notifier.posted.isEmpty)
        #expect(!w.isBelowThreshold)
        await w.setThresholdGB(50)
        #expect(h.notifier.posted.count == 1)
        #expect(h.world.settingsStore.load().lowSpaceThresholdGB == 50)
    }

    @Test func alertMentionsSafeTotalAfterAScan() async throws {
        let h = try Harness(authorization: .authorized)
        h.model.updateSettings { $0.lowSpaceNotifications = true }
        await h.model.scanAll()
        h.setFree(2)
        await h.watch().check()
        let alert = try #require(h.notifier.posted.first)
        #expect(alert.safeReclaimable == h.model.safeReclaimable)
        #expect(alert.body.contains("Quick Clean"))
    }

    @Test func launchAtLoginOnlyWhenToggled() throws {
        let h = try Harness()
        let w = h.watch()
        #expect(w.loginItemStatus == .disabled)
        w.setLaunchAtLogin(true)
        #expect(h.loginItem.current == .enabled && w.loginItemStatus.isOn)
        #expect(h.world.settingsStore.load().launchAtLogin)
        h.loginItem.needsApproval = true
        w.setLaunchAtLogin(false)
        w.setLaunchAtLogin(true)
        #expect(w.loginItemStatus == .requiresApproval)
        w.setLaunchAtLogin(false)
        #expect(h.loginItem.current == .disabled)
        #expect(!h.world.settingsStore.load().launchAtLogin)
    }

    @Test func weeklyRescanOnlyWhenEnabledAndDue() async throws {
        let h = try Harness()
        let w = h.watch()
        await h.model.scanAll()
        let last = try #require(h.model.lastFullScan)
        h.model.lastFullScan = h.clock.value.addingTimeInterval(-8 * 24 * 3600)
        #expect(last <= Date())
        #expect(!w.rescanDue(now: h.clock.value))      // off by default
        w.setWeeklyRescan(true)
        #expect(w.rescanDue(now: h.clock.value))
        h.model.lastFullScan = h.clock.value.addingTimeInterval(-6 * 24 * 3600)
        #expect(!w.rescanDue(now: h.clock.value))      // not a week yet
        h.clock.value = h.clock.value.addingTimeInterval(2 * 24 * 3600)
        #expect(w.rescanDue(now: h.clock.value))

        // Never during a clean / review.
        await h.model.quickClean()
        #expect(h.model.cleanSession != nil)
        #expect(!w.rescanDue(now: h.clock.value))
        h.model.cancelReview()

        await w.check()
        #expect(w.lastBackgroundRescan == h.clock.value)
        while h.model.isScanning || h.model.isScanningProjects { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.model.lastFullScan! > last)
    }

    @Test func noFirstScanFromTheWatcher() async throws {
        let h = try Harness()
        let w = h.watch()
        w.setWeeklyRescan(true)
        #expect(!w.rescanDue(now: h.clock.value))   // the window's launch scan comes first
    }

    // MARK: Quick clean from the menu bar / notification

    @Test func requestQuickCleanOnlyOpensTheReviewSheet() async throws {
        let h = try Harness()
        let m = h.model
        await m.scanProjects()
        m.selectStaleProjects()
        #expect(!m.checkedProjects.isEmpty)
        let derived = h.world.home.appending(path: "Library/Developer/Xcode/DerivedData")
        let before = try FileManager.default.contentsOfDirectory(atPath: derived.path).sorted()

        await m.requestQuickClean()          // no scan yet: scans first, then reviews
        #expect(m.hasScanned)
        let session = try #require(m.cleanSession)
        guard case .reviewing = session.phase else { Issue.record("not reviewing"); return }
        #expect(!session.plan.isEmpty)
        #expect(!session.plan.hibernatesProjects)
        #expect(session.plan.groups.allSatisfy { $0.tier == .safe })
        #expect(session.plan.groups.allSatisfy { !ProjectHibernation.isHibernationRule($0.ruleID) })
        // Nothing removed and nothing logged until the user confirms.
        #expect(try FileManager.default.contentsOfDirectory(atPath: derived.path).sorted() == before)
        #expect(m.history.isEmpty)

        // A second request while the sheet is open does nothing.
        await m.requestQuickClean()
        #expect(m.history.isEmpty)
    }

    @Test func requestQuickCleanDuringAScanWaitsForIt() async throws {
        let h = try Harness()
        let m = h.model
        m.startScanAll()
        await Task.yield()
        await m.requestQuickClean()   // pending if the scan is still running, else reviews straight away
        while m.isScanning || (m.pendingQuickClean && m.cleanSession == nil) { try await Task.sleep(for: .milliseconds(20)) }
        // Wait for the dry run to land.
        for _ in 0..<100 where m.cleanSession == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.cleanSession != nil)
        #expect(!m.pendingQuickClean)
        #expect(m.history.isEmpty)
    }
}
