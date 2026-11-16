import Foundation
import Testing
@testable import MajorTomCore

/// Linked folders: a working folder and a "drive" folder, both inside the test's temp directory.
@Suite("Linked folders") struct LinksTests {
    struct World {
        let f: Fixture
        let link: FolderLink
        let trash: URL
        var work: URL { link.sourceURL }
        var backup: URL { link.destinationURL }

        init() throws {
            f = try Fixture()
            let work = try f.dir("Studio")
            let drive = try f.dir("Drive", in: f.root)
            link = FolderLink(name: "Studio", source: work.path(percentEncoded: false),
                              destination: drive.appending(path: "Studio Backup").path(percentEncoded: false),
                              offloadAfterDays: 60)
            trash = f.root.appending(path: "Trash", directoryHint: .isDirectory)
        }

        func engine(thorough: Bool = false) -> LinkEngine {
            LinkEngine(link: link, home: f.home, remover: FolderTrashRemover(trashFolder: trash), thorough: thorough)
        }

        /// A file on either or both sides with the same content and date.
        func put(_ rel: String, bytes: Int = 5000, daysAgo: Double = 100, local: Bool = true, remote: Bool = true,
                 fill: UInt8 = 0x61) throws {
            let date = Date(timeIntervalSinceNow: -daysAgo * 86400)
            for (wanted, base) in [(local, work), (remote, backup)] where wanted {
                let url = base.appending(path: rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: fill, count: bytes).write(to: url)
                try FileTimes.set(url, modified: date)
            }
        }

        func entry(_ name: String) -> LinkEntry? { LinkScanner.report(link).entries.first { $0.name == name } }
    }

    @Test func reportTellsTheStatesApart() throws {
        let w = try World()
        try w.put("Done shoot/a.arw")
        try w.put("Done shoot/b.arw")
        try w.put("Half/a.mov")
        try w.put("Half/b.mov", remote: false)
        try w.put("New/a.nef", daysAgo: 1, remote: false)
        try w.put("Gone/a.braw", local: false)
        try w.put("Edited/set.avc", daysAgo: 100)
        try FileTimes.set(w.backup.appending(path: "Edited/set.avc"), modified: Date(timeIntervalSinceNow: -10 * 86400))
        try w.put(".DS_Store", remote: false)

        let report = LinkScanner.report(w.link)
        let states = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.name, $0.state) })
        #expect(states == ["Done shoot": .backedUp, "Half": .partial, "New": .notBackedUp, "Gone": .offloaded,
                           "Edited": .conflict])
        #expect(report.pendingCount == 2)
        #expect(report.offloadCandidates(afterDays: 60).map(\.name) == ["Done shoot"])
        #expect(report.offloadCandidates(afterDays: 365).isEmpty)
        #expect(report.entries.first { $0.name == "Done shoot" }?.kind == .photo)
    }

    @Test func backUpIsADryRunUnlessExecuted() throws {
        let w = try World()
        try w.put("Shoot/a.arw", remote: false)
        let dry = w.engine().backUp(execute: false)
        #expect(dry.files == 1 && !dry.executed)
        #expect(!FS.exists(w.backup.appending(path: "Shoot/a.arw")))
    }

    @Test func backUpCopiesVerifiesAndKeepsDates() throws {
        let w = try World()
        try w.put("Shoot/raw/a.arw", bytes: 9_000_000, remote: false)   // more than one copy chunk
        try w.put("Shoot/b.mov", remote: false)
        try w.put("Shoot/already.mov")
        try w.put("Loose.wav", remote: false)

        let report = w.engine().backUp(execute: true)
        #expect(report.problems.isEmpty)
        #expect(report.files == 3)
        let after = LinkScanner.report(w.link)
        #expect(after.pendingCount == 0)
        #expect(after.entries.allSatisfy { $0.state == .backedUp })
        #expect(try Data(contentsOf: w.backup.appending(path: "Shoot/raw/a.arw")) == Data(contentsOf: w.work.appending(path: "Shoot/raw/a.arw")))
        let leftovers = FileManager.default.enumerator(at: w.backup, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasSuffix(LinkEngine.partialSuffix) } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func backUpReplacesOlderCopiesButNeverNewerOnes() throws {
        let w = try World()
        try w.put("Edit/grade.drp", daysAgo: 50)
        try Data(repeating: 0x62, count: 7000).write(to: w.work.appending(path: "Edit/grade.drp"))  // edited now
        try w.put("Edit/notes.txt", daysAgo: 50)
        try Data(repeating: 0x63, count: 10).write(to: w.backup.appending(path: "Edit/notes.txt"))  // newer on backup

        let report = w.engine().backUp(execute: true)
        #expect(report.files == 1)
        #expect(try Data(contentsOf: w.backup.appending(path: "Edit/grade.drp")).count == 7000)
        #expect(try Data(contentsOf: w.backup.appending(path: "Edit/notes.txt")).count == 10)
        #expect(w.entry("Edit")?.state == .conflict)
    }

    @Test func offloadDryRunLeavesEverything() throws {
        let w = try World()
        try w.put("Shoot/a.arw")
        let report = w.engine().offload(entries: ["Shoot"], execute: false)
        #expect(report.files == 1 && report.problems.isEmpty)
        #expect(FS.exists(w.work.appending(path: "Shoot/a.arw")))
    }

    @Test func offloadMovesToTrashOnlyAfterVerifyingAndComesBack() throws {
        let w = try World()
        try w.put("Shoot/a.arw", bytes: 20_000_000)   // big enough for the sampled comparison
        try w.put("Shoot/sub/b.mov")
        try w.put("Keep/c.mov")
        let original = try Data(contentsOf: w.work.appending(path: "Shoot/sub/b.mov"))

        let report = w.engine().offload(entries: ["Shoot"], execute: true)
        #expect(report.problems.isEmpty && report.files == 2)
        #expect(!FS.exists(w.work.appending(path: "Shoot")))
        #expect(FS.exists(w.trash.appending(path: "Shoot/a.arw")))          // in the Trash, not deleted
        #expect(FS.exists(w.backup.appending(path: "Shoot/a.arw")))         // the backup is untouched
        #expect(FS.exists(w.work.appending(path: "Keep/c.mov")))
        #expect(w.entry("Shoot")?.state == .offloaded)

        let back = w.engine().bringBack(entries: ["Shoot"], execute: true)
        #expect(back.problems.isEmpty && back.files == 2)
        #expect(try Data(contentsOf: w.work.appending(path: "Shoot/sub/b.mov")) == original)
        #expect(w.entry("Shoot")?.state == .backedUp)
        #expect(FS.exists(w.backup.appending(path: "Shoot/sub/b.mov")))
    }

    @Test func offloadRefusesWhenAnythingIsMissingFromTheBackup() throws {
        let w = try World()
        try w.put("Shoot/a.arw")
        try w.put("Shoot/b.arw", remote: false)
        let report = w.engine().offload(entries: ["Shoot"], execute: true)
        #expect(report.files == 0)
        #expect(report.problems.first?.skipped?.contains("Back up first") == true)
        #expect(FS.exists(w.work.appending(path: "Shoot/a.arw")) && !FS.exists(w.trash.appending(path: "Shoot")))
    }

    @Test func offloadRefusesWhenTheBackupCopyIsCorrupt() throws {
        let w = try World()
        try w.put("Shoot/a.arw")
        try w.put("Shoot/b.arw", bytes: 6000)
        // Same size, same date, different bytes: only reading the content can tell.
        let bad = w.backup.appending(path: "Shoot/b.arw")
        try Data(repeating: 0x7A, count: 6000).write(to: bad)
        try FileTimes.set(bad, modified: Date(timeIntervalSinceNow: -100 * 86400))
        #expect(w.entry("Shoot")?.state == .backedUp)   // looks fine from the outside

        let report = w.engine().offload(entries: ["Shoot"], execute: true)
        #expect(report.files == 0)
        #expect(report.problems.first?.error?.contains("content differs") == true)
        #expect(FS.exists(w.work.appending(path: "Shoot/b.arw")) && !FS.exists(w.trash.appending(path: "Shoot")))
    }

    @Test func thoroughComparisonCatchesDamageInTheMiddleOfABigFile() throws {
        let w = try World()
        try w.put("Shoot/big.mov", bytes: 20_000_000)
        let bad = w.backup.appending(path: "Shoot/big.mov")
        var data = try Data(contentsOf: bad)
        data[10_000_000] = 0x00
        try data.write(to: bad)
        try FileTimes.set(bad, modified: Date(timeIntervalSinceNow: -100 * 86400))

        let report = w.engine(thorough: true).offload(entries: ["Shoot"], execute: true)
        #expect(report.files == 0 && FS.exists(w.work.appending(path: "Shoot/big.mov")))
    }

    @Test func offloadRefusesNamesThatLeaveTheFolderAndProtectedFolders() throws {
        let w = try World()
        try w.put("Shoot/a.arw")
        for name in ["../home", "Shoot/a.arw", "..", ""] {
            let report = w.engine().offload(entries: [name], execute: true)
            #expect(report.files == 0, "\(name) was accepted")
        }
        // A link whose working folder is the home folder: Documents is backed up, but never leaves as a whole.
        try w.f.file("Documents/x.pdf")
        let drive = try w.f.dir("HomeCopy", in: w.f.root)
        try w.f.file("Documents/x.pdf", in: drive)
        let date = Date(timeIntervalSinceNow: -100 * 86400)
        try FileTimes.set(w.f.home.appending(path: "Documents/x.pdf"), modified: date)
        try FileTimes.set(drive.appending(path: "Documents/x.pdf"), modified: date)
        let homeLink = FolderLink(name: "Home", source: w.f.home.path(percentEncoded: false),
                                  destination: drive.path(percentEncoded: false))
        let engine = LinkEngine(link: homeLink, home: w.f.home, remover: FolderTrashRemover(trashFolder: w.trash))
        let report = engine.offload(entries: ["Documents"], execute: true)
        #expect(report.files == 0 && report.problems.first?.error?.contains("protected") == true)
        #expect(FS.exists(w.f.home.appending(path: "Documents/x.pdf")))
    }

    @Test func nothingHappensWhileTheDriveIsAwayButTheLastStateIsRemembered() throws {
        let w = try World()
        try w.put("Shoot/a.arw")
        try w.put("New/b.arw", remote: false)
        let before = LinkScanner.report(w.link)
        #expect(before.destinationConnected)

        // "Unplug" the drive.
        try FileManager.default.moveItem(at: w.f.root.appending(path: "Drive"), to: w.f.root.appending(path: "Unplugged"))
        #expect(!w.link.destinationConnected)
        let away = LinkScanner.report(w.link, previous: before)
        #expect(!away.destinationConnected)
        let shoot = away.entries.first { $0.name == "Shoot" }
        #expect(shoot?.state == .backedUp && shoot?.remembered == true)
        #expect(away.entries.first { $0.name == "New" }?.state == .notBackedUp)
        #expect(away.offloadCandidates(afterDays: 1).isEmpty)   // remembered is not verified
        #expect(w.engine().offload(entries: ["Shoot"], execute: true).files == 0)
        #expect(w.engine().backUp(execute: true).files == 0)
        #expect(FS.exists(w.work.appending(path: "Shoot/a.arw")))

        // Changed since the last comparison: no longer assumed to be backed up.
        try Data(repeating: 0x62, count: 5000).write(to: w.work.appending(path: "Shoot/a.arw"))
        #expect(LinkScanner.report(w.link, previous: before).entries.first { $0.name == "Shoot" }?.remembered == false)
    }

    @Test func linkStoreRoundTrips() throws {
        let w = try World()
        let store = LinkStore(directory: w.f.root.appending(path: "links"))
        #expect(store.load().isEmpty)
        try store.save([w.link])
        #expect(store.load() == [w.link])
        try w.put("Shoot/a.arw")
        store.remember(LinkScanner.report(w.link))
        #expect(store.lastReport(w.link.id)?.entries.first?.name == "Shoot")
    }
}
