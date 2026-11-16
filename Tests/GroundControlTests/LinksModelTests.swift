import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// The linked-folders flow through the model, against the fixture's Studio folder and its fake drive.
@MainActor
@Suite("Ground Control model: linked folders and map")
struct LinksModelTests {
    final class World {
        let world: FixtureWorld
        init() throws { world = try FixtureWorld.create(scale: 0.05) }
        deinit { world.destroy() }
        var env: AppEnvironment { AppEnvironment.fixture(world) }
        func url(_ rel: String) -> URL { world.home.appending(path: rel) }
    }

    @Test func compareBackUpOffloadAndBringBack() async throws {
        let w = try World()
        let links = GroundControlModel(environment: w.env).links
        let link = try #require(links.selectedLink)
        await links.compareAll()
        let report = try #require(links.reports[link.id])
        #expect(report.pendingCount == 6)   // 2 of Club residency, 3 of Lookbook, the edited Festival set
        #expect(report.offloadCandidates(afterDays: link.offloadAfterDays).map(\.name) == ["2026-03 Starman promo"])

        // Nothing can be offloaded that isn't fully on the backup, however it is selected.
        links.checked = ["2026-11 Lookbook shoot", "2026-10 Club residency"]
        links.reviewOffload(link)
        #expect(links.run == nil)

        // Back up: review first, nothing copied until confirmed.
        links.reviewBackUp(link)
        #expect(links.run?.phase == .confirm && links.run?.files == 6)
        #expect(!FS.exists(w.world.driveFolder.appending(path: "Studio Backup/2026-11 Lookbook shoot")))
        await links.confirmRun()
        guard case .finished(let backup) = links.run?.phase else { Issue.record("backup didn't finish"); return }
        #expect(backup.problems.isEmpty && backup.files == 6)
        links.dismissRun()
        #expect(links.reports[link.id]?.pendingCount == 0)

        // Offload the suggested shoot: to the fixture Trash, backup kept, logged.
        links.checkOffloadCandidates(link)
        #expect(links.checked == ["2026-03 Starman promo", "2026-06 Festival visuals"])   // both old, both safe now
        links.checked = ["2026-03 Starman promo"]
        links.reviewOffload(link)
        #expect(links.run?.entries == ["2026-03 Starman promo"])
        await links.confirmRun()
        guard case .finished(let offload) = links.run?.phase else { Issue.record("offload didn't finish"); return }
        #expect(offload.problems.isEmpty && offload.files == 4)
        links.dismissRun()
        #expect(!FS.exists(w.url("Studio/2026-03 Starman promo")))
        #expect(FS.exists(w.world.trashFolder.appending(path: "2026-03 Starman promo/raw/DSC_0412.ARW")))
        #expect(FS.exists(w.world.driveFolder.appending(path: "Studio Backup/2026-03 Starman promo/raw/DSC_0412.ARW")))
        #expect(w.world.historyLog.entries().last?.ruleIDs == ["link-offload"])
        let entry = try #require(links.reports[link.id]?.entries.first { $0.name == "2026-03 Starman promo" })
        #expect(entry.state == .offloaded)

        // And back again.
        links.reviewBringBack(link, entry: entry)
        await links.confirmRun()
        links.dismissRun()
        #expect(FS.exists(w.url("Studio/2026-03 Starman promo/raw/DSC_0412.ARW")))
        #expect(links.reports[link.id]?.entries.first { $0.name == "2026-03 Starman promo" }?.state == .backedUp)
    }

    @Test func linksCanBeAddedAndRemovedWithoutTouchingFolders() async throws {
        let w = try World()
        let links = GroundControlModel(environment: w.env).links
        let source = w.url("Music"), drive = w.world.driveFolder.appending(path: "Music Backup")
        #expect(links.problem(source: source, destination: source) != nil)
        #expect(links.problem(source: source, destination: source.appending(path: "Stems")) != nil)
        let link = try #require(links.addLink(name: "", source: source, destination: drive))
        #expect(link.name == "Music" && links.links.count == 2)
        #expect(w.world.linkStore.load().count == 2)
        links.removeLink(link)
        #expect(links.links.count == 1 && FS.exists(source.appending(path: "Stems/set-intro.wav")))
    }

    @Test func mapScansZoomsAndRefusesProtectedFolders() async throws {
        let w = try World()
        let atlas = GroundControlModel(environment: w.env).atlas
        await atlas.scanIfNeeded()
        let map = try #require(atlas.map)
        #expect(map.root.bytes(of: .video) > 0 && map.origins.contains { $0.origin == .resolve })
        let studio = try #require(map.root.children.first { $0.name == "Studio" })
        atlas.zoom(to: studio)
        #expect(atlas.focus?.name == "Studio" && atlas.breadcrumbs.count == 2)
        atlas.zoomOut()
        #expect(atlas.focus?.path == map.root.path)
        let movies = try #require(map.root.children.first { $0.name == "Movies" })
        #expect(atlas.trashRefusal(movies) != nil)
        #expect(atlas.trashRefusal(studio) == nil)
        let library = try #require(map.root.children.first { $0.name == "Library" })
        #expect(library.children.allSatisfy { atlas.trashRefusal($0) != nil })
    }
}
