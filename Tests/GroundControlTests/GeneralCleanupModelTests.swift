import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// M5 rules through the model, against a fixture world (scale 0.1: the fixture's "large" files are 1–2 MB).
@MainActor
@Suite("Ground Control model: general cleanup")
struct GeneralCleanupModelTests {
    final class World {
        let world: FixtureWorld
        init() throws { world = try FixtureWorld.create(scale: 0.1) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            return e
        }
        func url(_ rel: String) -> URL { world.home.appending(path: rel) }
    }

    func scanned(_ w: World, largeMB: Int = 1) async -> GroundControlModel {
        let m = GroundControlModel(environment: w.env)
        m.updateSettings { $0.largeFileThresholdMB = largeMB; $0.oldFileMinimumMB = 0 }
        await m.scanAll()
        return m
    }

    func names(_ m: GroundControlModel, _ rule: String) -> Set<String> { Set(m.items(ruleID: rule).map(\.displayName)) }

    @Test func fixtureListsWhatItShouldAndNothingElse() async throws {
        let w = try World()
        let m = await scanned(w)
        #expect(names(m, "large-files") == ["Space Oddity (4K master).mov", "Ziggy Stardust tour.mov"])
        #expect(names(m, "installer-leftovers") == ["Xcode_26.1.xip", "Starman-2.4.dmg", "fonts.zip"])
        #expect(names(m, "old-files") == ["Taxes 2019.pdf", "Screen Recording 2024-06-01.mov", "notes.txt"])
        #expect(m.items(ruleID: "orphaned-app-data").map(\.id) == ["orphan:com.mars.spiders", "orphan:org.lowfi.soundandvision"])
        let everything = m.results.values.flatMap(\.items).compactMap(\.path?.path)
        for never in ["Documents/Code/heliosphere", "Documents/launch-site", "Photos Library.photoslibrary", "Movies/TV",
                      "Audio Previews", "com.ziggy", "com.apple.", "com.vercel.cli", "io.stellar", "justforoneday"] {
            #expect(!everything.contains { $0.contains(never) }, "listed something under \(never)")
        }
    }

    @Test func generalCleanupIsNeverInQuickClean() async throws {
        let w = try World()
        let m = await scanned(w)
        m.selectAllSafe()
        let fileRules = Set(m.rules.filter { $0.category == .files }.map(\.id))
        #expect(fileRules.count == 4)
        #expect(!m.checkedItems.contains { fileRules.contains($0.ruleID) })
        #expect(fileRules.allSatisfy { m.rule(id: $0)?.tier == .review })
    }

    @Test func confirmMovesToTheFixtureTrash() async throws {
        let w = try World()
        let m = await scanned(w)
        let taxes = try #require(m.items(ruleID: "old-files").first { $0.displayName == "Taxes 2019.pdf" })
        let mars = try #require(m.items(ruleID: "orphaned-app-data").first)
        m.setChecked(true, ruleID: "old-files", itemID: taxes.id)
        m.setChecked(true, ruleID: "orphaned-app-data", itemID: mars.id)
        await m.review()
        #expect(m.cleanSession?.canConfirm == true)
        await m.confirmClean()
        guard case .finished(let report) = m.cleanSession?.phase else { Issue.record("not finished"); return }
        #expect(report.outcomes.allSatisfy { $0.status == .cleaned })
        #expect(report.outcomes.allSatisfy { $0.method == .trash })
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: w.url("Documents/Taxes 2019.pdf").path))
        #expect(fm.fileExists(atPath: w.world.trashFolder.appending(path: "Taxes 2019.pdf").path))
        #expect(!fm.fileExists(atPath: w.url("Library/Caches/com.mars.spiders").path))
        #expect(fm.fileExists(atPath: w.world.trashFolder.appending(path: "com.mars.spiders").path))
        #expect(m.history.first?.items.allSatisfy { $0.method == "move to Trash" } == true)
        #expect(!names(m, "old-files").contains("Taxes 2019.pdf"))
        #expect(m.items(ruleID: "orphaned-app-data").map(\.id) == ["orphan:org.lowfi.soundandvision"])
    }

    @Test func changingThresholdsRescansTheFileRules() async throws {
        let w = try World()
        let m = await scanned(w)
        #expect(m.items(ruleID: "large-files").count == 2)
        let before = try #require(m.results["large-files"]?.scannedAt)
        m.updateSettings { $0.largeFileThresholdMB = 100 }
        for _ in 0..<100 where (m.results["large-files"]?.scannedAt ?? before) == before || m.isScanning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(m.items(ruleID: "large-files").isEmpty)
        // The two former large files are old enough to show up as old files now.
        #expect(names(m, "old-files").contains("Ziggy Stardust tour.mov"))
    }
}
