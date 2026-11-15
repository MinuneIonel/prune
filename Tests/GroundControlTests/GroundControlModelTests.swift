import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// Every test runs against a fresh fixture world in the temp directory; nothing outside it is touched.
@MainActor
@Suite("Ground Control model")
struct GroundControlModelTests {
    final class World {
        let world: FixtureWorld
        init() throws { world = try FixtureWorld.create(scale: 0.01) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            return e
        }
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: world.home.appending(path: rel).path) }
    }

    func scanned(_ w: World) async -> GroundControlModel {
        let m = GroundControlModel(environment: w.env)
        await m.scanAll()
        return m
    }

    @Test func fixtureModeIsOptIn() {
        #expect(!AppEnvironment.wantsFixture(arguments: ["MajorTom"], environment: [:]))
        #expect(AppEnvironment.wantsFixture(arguments: ["MajorTom", "--fixture"], environment: [:]))
        #expect(AppEnvironment.wantsFixture(arguments: ["MajorTom"], environment: ["MAJORTOM_FIXTURE": "1"]))
        #expect(!AppEnvironment.wantsFixture(arguments: ["MajorTom"], environment: ["MAJORTOM_FIXTURE": "0"]))
    }

    @Test func fixtureWorldStaysInsideItsRoot() throws {
        let w = try World()
        let ctx = w.world.context
        #expect(ctx.home.path.hasPrefix(w.world.root.path))
        #expect(ctx.allowedSystemRoots.isEmpty)
        for rule in w.world.rules {
            for base in rule.baseDirectories(ctx) { #expect(base.path.hasPrefix(w.world.home.path)) }
        }
        #expect(w.world.historyLog.url.path.hasPrefix(w.world.root.path))
        #expect(w.world.settingsStore.url.path.hasPrefix(w.world.root.path))
    }

    @Test func scanFillsResultsAndTotals() async throws {
        let w = try World()
        let m = await scanned(w)
        #expect(m.results.count == w.world.rules.count)
        #expect(m.scanState != .idle)
        #expect(!m.isScanning)
        #expect(m.items(ruleID: "fx-derived-data").count == 3)
        #expect(m.reclaimable(ruleID: "fx-derived-data") > 0)
        // Protected Node version and report-only snapshots don't count as reclaimable.
        let node = m.items(ruleID: "fx-node-versions")
        #expect(node.contains { $0.isProtected })
        #expect(m.reclaimable(ruleID: "fx-node-versions") < m.totalFound(ruleID: "fx-node-versions"))
        #expect(m.reclaimable(ruleID: "fx-snapshots") == 0)
        let tiers = m.reclaimableByTier
        #expect(m.totalReclaimable == tiers.values.reduce(0, +))
        #expect(m.reclaimable(category: nil) == m.totalReclaimable)
        #expect(m.categories.contains(.xcode) && !m.categories.contains(.ides))
        // Biggest reclaimable first.
        let sizes = m.rules(in: nil).map { m.reclaimable(ruleID: $0.id) }
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func selectionRefusesProtectedAndReportOnly() async throws {
        let w = try World()
        let m = await scanned(w)
        let protected = try #require(m.items(ruleID: "fx-node-versions").first { $0.isProtected })
        m.setChecked(true, ruleID: "fx-node-versions", itemID: protected.id)
        #expect(m.checkedItems.isEmpty)
        let snap = try #require(m.items(ruleID: "fx-snapshots").first)
        m.setChecked(true, ruleID: "fx-snapshots", itemID: snap.id)
        #expect(m.checkedItems.isEmpty)
        // Non-runnable actions can't be selected; runnable ones can.
        m.setChecked(true, ruleID: "fx-snapshots", actionID: "delete-all")
        #expect(m.checkedActions.isEmpty)
        m.setChecked(true, ruleID: "fx-pnpm", actionID: "prune")
        #expect(m.checkedActions.count == 1)
    }

    @Test func ruleCheckStateAndToggle() async throws {
        let w = try World()
        let m = await scanned(w)
        let ids = m.items(ruleID: "fx-derived-data").map(\.id)
        #expect(m.checkState(ruleID: "fx-derived-data") == .none)
        m.setChecked(true, ruleID: "fx-derived-data", itemID: ids[0])
        #expect(m.checkState(ruleID: "fx-derived-data") == .some)
        m.setAllChecked(true, ruleID: "fx-derived-data")
        #expect(m.checkState(ruleID: "fx-derived-data") == .all)
        m.toggle(ruleID: "fx-derived-data", itemIDs: ids)
        #expect(m.checkState(ruleID: "fx-derived-data") == .none)
        // Rule with a protected item: "all" means all cleanable.
        m.setAllChecked(true, ruleID: "fx-node-versions")
        #expect(m.checkState(ruleID: "fx-node-versions") == .all)
        #expect(m.checkedItems.filter { $0.ruleID == "fx-node-versions" }.count == 1)
    }

    @Test func quickCleanSelectsOnlySafeItems() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-gradle")
        m.selectAllSafe()
        let safeRules = Set(w.world.rules.filter { $0.tier == .safe }.map(\.id))
        #expect(!m.checkedItems.isEmpty)
        #expect(m.checkedItems.allSatisfy { safeRules.contains($0.ruleID) })
        let expected = safeRules.reduce(0) { $0 + m.items(ruleID: $1).count }
        #expect(m.checkedItems.count == expected)
        #expect(m.plan.estimatedBytes == m.safeReclaimable)
        #expect(Set(m.plan.groups.map(\.tier)) == [.safe])
    }

    @Test func planGroupsByRuleWithCopyAndActions() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-gradle")
        m.setAllChecked(true, ruleID: "fx-logs")
        m.setChecked(true, ruleID: "fx-pnpm", actionID: "prune")
        let plan = m.plan
        #expect(plan.groups.map(\.ruleID) == ["fx-logs", "fx-gradle", "fx-pnpm"])  // safe first, then by size
        let gradle = try #require(plan.groups.first { $0.ruleID == "fx-gradle" })
        #expect(gradle.items.count == 2)
        #expect(!gradle.impact.isEmpty && !gradle.recovery.isEmpty && !gradle.regenCost.isEmpty)
        #expect(plan.actionRequests == [ActionRequest(ruleID: "fx-pnpm", actionID: "prune")])
        #expect(plan.itemCount == 4 && plan.actionCount == 1)
        #expect(plan.sizes.count == 4)
    }

    @Test func reviewIsADryRun() async throws {
        let w = try World()
        let m = await scanned(w)
        await m.quickClean()
        let session = try #require(m.cleanSession)
        #expect(session.canConfirm)
        let report: CleanReport
        if case .reviewing(let r?) = session.phase { report = r } else { Issue.record("no dry run"); return }
        #expect(report.dryRun)
        #expect(report.outcomes.allSatisfy { $0.status == .wouldClean })
        #expect(session.confirmedEstimate == session.plan.estimatedBytes)
        // Nothing was touched, nothing logged.
        #expect(w.exists(".npm/_cacache"))
        #expect(w.exists("Library/Developer/Xcode/DerivedData/Telescope-abcdefgh"))
        #expect(m.history.isEmpty)
        m.cancelReview()
        #expect(m.cleanSession == nil)
        #expect(w.exists(".npm/_cacache"))
    }

    @Test func confirmCleansFixtureEndToEnd() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-gradle")
        m.setChecked(true, ruleID: "fx-pnpm", actionID: "prune")
        m.setAllChecked(true, ruleID: "fx-node-versions")
        await m.review()
        await m.confirmClean()

        guard case .finished(let report)? = m.cleanSession?.phase else { Issue.record("not finished"); return }
        #expect(!report.dryRun)
        #expect(report.reclaimedBytes != nil)
        #expect(report.outcomes.count == 4)
        #expect(report.outcomes.allSatisfy { $0.status == .cleaned })
        // Selected items are gone, everything else is still there.
        #expect(!w.exists(".gradle/wrapper/dists/gradle-8.7-bin"))
        #expect(!w.exists(".gradle/wrapper/dists/gradle-8.10-bin"))
        #expect(!w.exists(".nvm/versions/node/v18.20.4"))
        #expect(w.exists(".nvm/versions/node/v22.11.0"))  // protected default
        #expect(w.exists(".gradle/wrapper/dists"))
        #expect(w.exists(".npm/_cacache"))
        #expect(w.exists("Library/pnpm/store"))  // prune was simulated, never run
        #expect(w.world.runner.recordedCalls.contains(["pnpm", "store", "prune"]))
        // Logged to the fixture history, selection cleared, affected rules rescanned.
        #expect(m.history.count == 1)
        #expect(m.history.first?.items.count == 4)
        #expect(m.checkedItems.isEmpty && m.checkedActions.isEmpty)
        #expect(m.items(ruleID: "fx-gradle").isEmpty)
        #expect(m.items(ruleID: "fx-node-versions").count == 1)
        m.dismissResult()
        #expect(m.cleanSession == nil)
    }

    @Test func confirmWithoutReviewDoesNothing() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-gradle")
        await m.confirmClean()
        #expect(w.exists(".gradle/wrapper/dists/gradle-8.7-bin"))
        #expect(m.history.isEmpty)
    }

    @Test func dryRunFlagsItemsThatVanished() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-gradle")
        try FileManager.default.removeItem(at: w.world.home.appending(path: ".gradle/wrapper/dists/gradle-8.7-bin"))
        await m.review()
        let session = try #require(m.cleanSession)
        let gone = session.plan.groups[0].items.first { $0.displayName == "gradle-8.7-bin" }!
        guard case .skipped? = session.dryRunStatus(ruleID: "fx-gradle", itemID: gone.id) else {
            Issue.record("expected skipped"); return
        }
        #expect(session.canConfirm)  // the other one is still there
    }

    @Test func disabledRulesAndIgnoredPaths() async throws {
        let w = try World()
        let m = await scanned(w)
        m.setAllChecked(true, ruleID: "fx-logs")
        m.setRuleEnabled(false, ruleID: "fx-logs")
        #expect(!m.rules.contains { $0.id == "fx-logs" })
        #expect(m.checkedItems.isEmpty)
        #expect(w.world.settingsStore.load().disabledRuleIDs == ["fx-logs"])
        m.setRuleEnabled(true, ruleID: "fx-logs")
        #expect(m.rules.contains { $0.id == "fx-logs" })

        let item = try #require(m.items(ruleID: "fx-derived-data").first)
        m.setChecked(true, ruleID: "fx-derived-data", itemID: item.id)
        m.ignore(item)
        #expect(!m.items(ruleID: "fx-derived-data").contains { $0.id == item.id })
        #expect(m.checkedItems.isEmpty)
        m.unignore(path: item.path!.path)
        #expect(m.items(ruleID: "fx-derived-data").contains { $0.id == item.id })
    }

    @Test func demoAutomationIsFixtureOnly() async throws {
        let w = try World()
        var live = w.env
        live.fixture = nil  // pretend this is the real machine (rules still point at the fixture)
        let m = GroundControlModel(environment: live)
        await m.runDemo("clean")
        #expect(m.cleanSession == nil)
        #expect(m.results.isEmpty)
        #expect(w.exists(".npm/_cacache"))
    }

    @Test func fullDiskAccessProbe() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MajorTomFDA-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FullDiskAccess.status(probing: [root.appending(path: "missing")]) == .unknown)
        let readable = root.appending(path: "readable")
        try Data("x".utf8).write(to: readable)
        #expect(FullDiskAccess.status(probing: [root.appending(path: "missing"), readable]) == .granted)
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(FullDiskAccess.status(probing: [locked]) == .denied)
    }
}
