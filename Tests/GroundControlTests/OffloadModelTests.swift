import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// NAS offload through the model, against a fixture world whose "NAS" is a folder reported as a mounted SMB share.
@MainActor
@Suite("Ground Control model: NAS offload")
struct OffloadModelTests {
    final class World {
        let world: FixtureWorld
        init() throws { world = try FixtureWorld.create(scale: 0.1) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            return e
        }
    }

    func model(_ w: World) async -> GroundControlModel {
        let m = GroundControlModel(environment: w.env)
        m.updateSettings { $0.largeFileThresholdMB = 1; $0.oldFileMinimumMB = 0 }
        await m.scanOffloadCandidates()
        return m
    }

    func wait(_ m: GroundControlModel) async {
        await m.offloadTask?.value
    }

    @Test func fixtureCandidatesAndDefaultDestination() async throws {
        let w = try World()
        let m = await model(w)
        #expect(m.offloadDestination?.path == w.world.nasFolder.path)
        #expect(m.destinationCheck.isReady)
        let names = Set(m.offloadCandidates.map(\.path.lastPathComponent))
        #expect(names.isSuperset(of: ["stellar", "acme-notes.reactnative", "rusty", "Telescope 1.0.xcarchive",
                                      "Ziggy Stardust tour.mov", "Taxes 2019.pdf"]))
        #expect(!names.contains("client site"))                       // active project
        #expect(!names.contains("Space Oddity (4K master).mov"))       // large but used 3 days ago
        let stellar = try #require(m.offloadCandidates.first { $0.path.lastPathComponent == "stellar" })
        #expect(stellar.shouldHibernateFirst)
        #expect(m.offloadCandidates.allSatisfy { ($0.size ?? 0) > 0 })
    }

    @Test func offloadIsNeverPartOfQuickClean() async throws {
        let w = try World()
        let m = await model(w)
        await m.scanAll()
        m.selectAllSafe()
        #expect(m.checkedOffloads.isEmpty)
        #expect(m.plan.groups.allSatisfy { $0.tier == .safe })
    }

    @Test func reviewConfirmOffloadThenRestore() async throws {
        let w = try World()
        let m = await model(w)
        let archive = try #require(m.offloadCandidates.first { $0.kind == .xcodeArchive })
        let movie = try #require(m.offloadCandidates.first { $0.path.lastPathComponent == "Ziggy Stardust tour.mov" })
        m.setOffloadChecked(true, archive)
        m.setOffloadChecked(true, movie)
        await m.reviewOffload()
        #expect(m.offloadSession?.canConfirm == true)
        // Review is a dry run: nothing copied yet.
        #expect(OffloadLayout.manifests(in: w.world.nasFolder).isEmpty)
        m.confirmOffload()
        await wait(m)
        guard case .finished(let report)? = m.offloadSession?.phase else { Issue.record("not finished"); return }
        #expect(report.results.allSatisfy { $0.status == .offloaded(trashed: true) }, "\(report.results.map(\.status))")
        #expect(!FileManager.default.fileExists(atPath: archive.path.path))
        #expect(FileManager.default.fileExists(atPath: w.world.trashFolder.appending(path: "Telescope 1.0.xcarchive").path))
        #expect(m.offloadRecords.count == 2)
        #expect(m.reachableOffloads.count == 2)
        #expect(m.history.first?.items.allSatisfy { $0.method.contains("offload") } == true)
        #expect(m.checkedOffloads.isEmpty)
        #expect(!m.offloadCandidates.contains { $0.id == archive.id })
        m.dismissOffload()

        let record = try #require(m.offloadRecords.first { $0.manifest.kind == .xcodeArchive })
        await m.reviewRestore(record)
        #expect(m.restoreSession?.canConfirm == true)
        m.confirmRestore()
        await wait(m)
        guard case .finished(let result)? = m.restoreSession?.phase else { Issue.record("restore not finished"); return }
        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: archive.path.appending(path: "Info.plist").path))
        #expect(m.offloadRecords.first { $0.id == record.id }?.restores.count == 1)
        m.dismissRestore()

        // A second restore to the same place is refused at review.
        await m.reviewRestore(record)
        guard case .reviewing(let again?)? = m.restoreSession?.phase else { Issue.record("no review"); return }
        #expect(again.error == .alreadyExists(archive.path.path))
        #expect(m.restoreSession?.canConfirm == false)
    }

    @Test func unmountedShareBlocksTheReview() async throws {
        let w = try World()
        w.world.nasProbe.mounted = false
        let m = await model(w)
        #expect(!m.destinationCheck.isReady)
        let c = try #require(m.offloadCandidates.first { $0.kind == .file })
        m.setOffloadChecked(true, c)
        await m.reviewOffload()
        #expect(m.offloadSession?.canConfirm == false)
        #expect(FileManager.default.fileExists(atPath: c.path.path))
    }

    @Test func cancellingLeavesEverythingInPlace() async throws {
        let w = try World()
        var env = w.env
        env.offloadHooks.writeFault = { _ in usleep(50_000); return nil }  // slow "NAS"
        let m = GroundControlModel(environment: env)
        m.updateSettings { $0.largeFileThresholdMB = 1; $0.oldFileMinimumMB = 0 }
        await m.scanOffloadCandidates()
        let projects = m.offloadCandidates.filter { $0.kind == .project }
        for c in projects { m.setOffloadChecked(true, c) }
        await m.reviewOffload()
        m.confirmOffload()
        try await Task.sleep(for: .milliseconds(300))
        m.cancelOffload()
        await wait(m)
        guard case .finished(let report)? = m.offloadSession?.phase else { Issue.record("not finished"); return }
        #expect(report.results.contains { $0.status == .cancelled })
        for r in report.results where r.status == .cancelled {
            #expect(FileManager.default.fileExists(atPath: r.candidate.path.path))
        }
        #expect(OffloadLayout.partials(in: w.world.nasFolder).isEmpty)
    }

    @Test func offloadDemoIsFixtureOnly() async throws {
        let live = GroundControlModel(environment: AppEnvironment(
            rules: [], context: RuleContext(home: FileManager.default.temporaryDirectory.appending(path: "nowhere-\(UUID())")),
            history: HistoryLog(url: FileManager.default.temporaryDirectory.appending(path: "h-\(UUID()).jsonl")),
            settingsStore: SettingsStore(url: FileManager.default.temporaryDirectory.appending(path: "s-\(UUID()).json")),
            offloads: OffloadStore(directory: FileManager.default.temporaryDirectory.appending(path: "o-\(UUID())"))))
        await live.runDemo("offload")
        #expect(live.offloadSession == nil)
        #expect(live.offloadCandidatesState == .idle)
    }
}
