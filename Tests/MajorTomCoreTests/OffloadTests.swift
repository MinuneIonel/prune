import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MajorTomCore

/// NAS offload against temp folders: the "NAS" is `<fixture>/NAS`, reported as a mounted SMB share by `FakeVolumeProbe`.
@Suite("NAS offload")
struct OffloadTests {
    final class World {
        let fx: Fixture
        let nas: URL
        let probe: FakeVolumeProbe
        let remover: RecordingRemover
        var settings: Settings

        init() throws {
            fx = try Fixture()
            nas = try fx.dir("NAS", in: fx.root)
            probe = FakeVolumeProbe(root: nas)
            remover = RecordingRemover(trashFolder: fx.root.appending(path: "Trash"))
            settings = fx.fileSettings
        }

        var store: OffloadStore { OffloadStore(directory: fx.root.appending(path: "offloads")) }
        var trash: URL { fx.root.appending(path: "Trash") }

        func engine(cap: Int64? = nil, hooks: OffloadEngine.Hooks = .init(), destination: URL? = nil) -> OffloadEngine {
            var e = OffloadEngine(destination: destination ?? nas, probe: probe, context: fx.context(settings: settings),
                                  rules: [FixtureRules.archives] + FilesRules.all, git: FakeRunner(), store: store,
                                  remover: remover, history: fx.historyLog, checksumCapBytes: cap, hooks: hooks)
            e.mountCheckInterval = 256 * 1024
            return e
        }

        /// A stale project with the things SMB is bad at: odd names, long paths, symlinks, xattrs, empty files,
        /// a multi-chunk file, an executable, and a `.git` folder.
        @discardableResult
        func project(_ name: String = "rusty") throws -> URL {
            let p = try fx.dir("WebstormProjects/\(name)")
            try fx.file("Cargo.toml", bytes: 40, in: p)
            try fx.file("src/main.rs", bytes: 300, in: p)
            try fx.file("src/what:is*this?.rs", bytes: 10, in: p)
            try fx.file("notes/Ünïcødé – naïve café.md", bytes: 77, in: p)
            try fx.file("notes/trailing dot.", bytes: 5, in: p)
            try fx.file("notes/CON", bytes: 5, in: p)
            try fx.file("empty.txt", bytes: 0, in: p)
            let deep = String(repeating: "deeply-nested-folder-name/", count: 12) + "leaf-file-with-a-long-name.txt"
            try fx.file(deep, bytes: 123, in: p)
            let big = p.appending(path: "assets/blob.bin")
            try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<(9 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: big)
            try fx.file(".git/HEAD", bytes: 23, in: p)
            try fx.file(".git/objects/ab/cdef", bytes: 1000, in: p)
            let tool = try fx.file("bin/tool.sh", bytes: 20, in: p)
            chmod(tool.path, 0o755)
            let tagged = p.appending(path: "src/main.rs").path
            #expect(setxattr(tagged, "com.example.tag", "orbit", 5, 0, XATTR_NOFOLLOW) == 0)
            let longAgo = Date(timeIntervalSinceNow: -86400 * 200)
            try FixtureWorld.setModificationDates(in: p, to: longAgo)
            for (name, target) in [("link-to-main", "src/main.rs"), ("dangling", "../nowhere")] {
                let link = p.appending(path: name).path
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
                OffloadEngine.setTimes(link, longAgo)
            }
            OffloadEngine.setTimes(p.path, longAgo)
            return p
        }

        func projectCandidate(_ p: URL) -> OffloadCandidate {
            OffloadCandidate(kind: .project, path: p, displayName: p.lastPathComponent, size: 10_000_000)
        }

        func nasFiles() -> [String] {
            let e = FileManager.default.enumerator(atPath: nas.path)
            return (e?.allObjects as? [String] ?? []).sorted()
        }
    }

    // MARK: Happy path

    @Test func projectRoundTripIsByteIdentical() async throws {
        let w = try World()
        let p = try w.project()
        let engine = w.engine()
        let report = await engine.offload([w.projectCandidate(p)], execute: true)
        let r = try #require(report.results.first)
        #expect(r.status == .offloaded(trashed: true), "\(r.status)")
        #expect(!FileManager.default.fileExists(atPath: p.path))
        #expect(w.remover.trashed.map(\.path) == [p.path])
        #expect(w.remover.deleted.isEmpty)
        let trashed = w.trash.appending(path: "rusty")

        // Layout: <nas>/projects/rusty/<stamp>/{rusty.tar, manifest.json}, nothing partial.
        let record = try #require(r.record)
        #expect(record.manifest.archivePath.hasPrefix(w.nas.appending(path: "projects/rusty").path + "/"))
        #expect(!record.manifest.archivePath.hasSuffix(".partial"))
        #expect(FileManager.default.fileExists(atPath: record.manifest.payloadPath))
        #expect(FileManager.default.fileExists(atPath: record.manifest.manifestPath))
        #expect(OffloadLayout.partials(in: w.nas).isEmpty)
        #expect(record.manifest.format == .tar)
        #expect(record.manifest.symlinkCount == 2)
        #expect(w.store.records().map(\.id) == [record.id])
        #expect(w.store.manifest(id: record.id)?.entries.count == record.manifest.fileCount + record.manifest.directoryCount + 2)
        #expect(w.fx.historyLog.entries().last?.items.first?.method == "offload to external drive, then move to Trash")

        // Standard tar can read it.
        let untar = try w.fx.dir("untar", in: w.fx.root)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-xpf", record.manifest.payloadPath, "-C", untar.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        try expectIdentical(trashed, untar.appending(path: "rusty"), xattrs: false)

        // Restore to the original place: identical to what went to the Trash, xattrs and modes included.
        let restored = await engine.restore(record, execute: true)
        #expect(restored.succeeded, "\(String(describing: restored.error))")
        #expect(restored.target.path == p.path)
        try expectIdentical(trashed, p, xattrs: true)
        // The NAS copy is still there; the restore is recorded; no staging folder left behind.
        #expect(FileManager.default.fileExists(atPath: record.manifest.payloadPath))
        #expect(w.store.record(id: record.id)?.restores.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.deletingLastPathComponent().path)
            .allSatisfy { !$0.hasPrefix(".majortom-restore") })
    }

    @Test func singleFileIsCopiedPlainWithItsAttributesInTheManifest() async throws {
        let w = try World()
        let movie = try w.fx.userFile("Movies/Ziggy: live?.mov", mb: 3, daysAgo: 400)
        #expect(setxattr(movie.path, "com.apple.metadata:kMDItemWhereFroms", "x", 1, 0, XATTR_NOFOLLOW) == 0)
        let engine = w.engine()
        let candidates = await engine.candidates(projects: [])
        let c = try #require(candidates.first { $0.path == movie.standardizedFileURL })
        #expect(c.kind == .file)
        let report = await engine.offload([c], execute: true)
        let record = try #require(report.results.first?.record)
        #expect(report.results.first?.status == .offloaded(trashed: true))
        #expect(record.manifest.format == .file)
        #expect(record.manifest.payloadName == "Ziggy_ live_.mov")
        #expect(record.manifest.fileXattrs?["com.apple.metadata:kMDItemWhereFroms"] == Data("x".utf8))
        let restored = await engine.restore(record, execute: true)
        #expect(restored.succeeded, "\(String(describing: restored.error))")
        try expectIdentical(w.trash.appending(path: "Ziggy: live?.mov"), movie, xattrs: true)
    }

    @Test func xcodeArchiveIsACandidateAndRoundTrips() async throws {
        let w = try World()
        try w.fx.file("Library/Developer/Xcode/Archives/2026-03-01/Telescope 1.0.xcarchive/Info.plist", bytes: 900)
        try w.fx.file("Library/Developer/Xcode/Archives/2026-03-01/Telescope 1.0.xcarchive/dSYMs/T.dSYM/x", bytes: 5000)
        let engine = w.engine()
        let c = try #require(await engine.candidates(projects: []).first { $0.kind == .xcodeArchive })
        #expect(c.ruleID == "fx-archives")
        let report = await engine.offload([c], execute: true)
        let record = try #require(report.results.first?.record)
        #expect(report.results.first?.status == .offloaded(trashed: true))
        #expect(record.manifest.archivePath.contains("/xcode-archives/Telescope 1.0.xcarchive/"))
        #expect(await engine.restore(record, execute: true).succeeded)
        try expectIdentical(w.trash.appending(path: "Telescope 1.0.xcarchive"), c.path, xattrs: true)
    }

    @Test func dryRunIsTheDefaultAndWritesNothing() async throws {
        let w = try World()
        let p = try w.project()
        let report = await w.engine().offload([w.projectCandidate(p)])
        #expect(report.dryRun)
        #expect(report.results.first?.status == .wouldOffload)
        #expect((report.results.first?.payloadBytes ?? 0) > 9_000_000)
        #expect(w.nasFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: p.path))
        #expect(w.remover.trashed.isEmpty)
        #expect(w.store.records().isEmpty)
    }

    @Test func eachOffloadGetsItsOwnFolderAndNothingIsOverwritten() throws {
        let w = try World()
        let date = Date()
        let a = try OffloadLayout.claim(destination: w.nas, kind: .project, name: "Same", date: date)
        let b = try OffloadLayout.claim(destination: w.nas, kind: .project, name: "same", date: date)
        #expect(a.partial != b.partial)
        #expect(b.final.lastPathComponent.hasSuffix("Z-2") || b.final.deletingLastPathComponent() != a.final.deletingLastPathComponent())
        #expect(a.partial.lastPathComponent.hasSuffix(".partial"))
    }

    // MARK: Failures leave the original untouched

    func expectUntouched(_ w: World, _ p: URL, before: [SourceNode]) throws {
        #expect(FileManager.default.fileExists(atPath: p.path))
        #expect(SourceTree.differences(before, try SourceTree.walk(p).nodes).isEmpty)
        #expect(w.remover.trashed.isEmpty)
        #expect(w.remover.deleted.isEmpty)
        #expect(w.store.records().isEmpty)
    }

    @Test func externalDrivesCountButTheStartupDiskNeverDoes() {
        #expect(LiveVolumeProbe.isExternalMount("/Volumes/Shoots SSD"))
        #expect(!LiveVolumeProbe.isExternalMount("/"))
        #expect(!LiveVolumeProbe.isExternalMount("/System/Volumes/Data"))
        #expect(!LiveVolumeProbe.isExternalMount("/Volumes/"))
        // A real folder on this Mac's own disk (what an unplugged drive leaves behind) is refused.
        let home = FileManager.default.temporaryDirectory
        if case .ready = DestinationCheck.check(home, probe: LiveVolumeProbe()) { Issue.record("the internal disk was accepted") }
    }

    @Test func notMountedRefusesBeforeWritingAnything() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        w.probe.mounted = false
        let report = await w.engine().offload([w.projectCandidate(p)], execute: true)
        #expect(!report.destination.isReady)
        if case .notNetwork = report.destination {} else { Issue.record("expected notNetwork, got \(report.destination)") }
        guard case .failed(let msg)? = report.results.first?.status else { Issue.record("not failed"); return }
        #expect(msg.contains("not on the external drive"))
        #expect(w.nasFiles().isEmpty)
        try expectUntouched(w, p, before: before)

        // A destination folder that doesn't exist at all.
        let missing = await w.engine(destination: w.nas.appending(path: "gone")).offload([w.projectCandidate(p)], execute: true)
        if case .missing = missing.destination {} else { Issue.record("expected missing") }
        try expectUntouched(w, p, before: before)
    }

    @Test func realProbeSaysATempFolderIsNotANetworkShare() throws {
        let w = try World()
        let check = DestinationCheck.check(w.nas, probe: LiveVolumeProbe())
        if case .notNetwork = check {} else { Issue.record("a local temp folder must not count as the NAS: \(check)") }
    }

    @Test func insufficientSpaceRefusesBeforeCopying() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        w.probe.availableBytes = 5_000_000
        let report = await w.engine().offload([w.projectCandidate(p)], execute: true)
        guard case .failed(let msg)? = report.results.first?.status else { Issue.record("not failed"); return }
        #expect(msg.contains("not enough space"))
        #expect(w.nasFiles().isEmpty)
        try expectUntouched(w, p, before: before)
    }

    @Test func checksumMismatchFailsAndRemovesThePartialCopy() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        let hooks = OffloadEngine.Hooks(afterPayloadWritten: { url in corrupt(url, at: 3000) })
        let report = await w.engine(hooks: hooks).offload([w.projectCandidate(p)], execute: true)
        guard case .failed(let msg)? = report.results.first?.status else { Issue.record("not failed"); return }
        #expect(msg.contains("verification failed"))
        #expect(report.results.first?.partialNote?.contains("removed") == true)
        #expect(OffloadLayout.partials(in: w.nas).isEmpty)
        #expect(OffloadLayout.manifests(in: w.nas).isEmpty)
        try expectUntouched(w, p, before: before)
    }

    @Test func mismatchInsideALargeFileIsCaughtByItsSample() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        // Cap of 1 MB: blob.bin (9 MB) is compared by its first and last 4 MiB, not re-read in full. Corrupt a byte
        // in its last 4 MiB.
        let hooks = OffloadEngine.Hooks(afterPayloadWritten: { url in
            guard let src = try? PayloadSource(path: url.path) else { return }
            while let e = try? Tar.next(src) {
                if e.name.hasSuffix("assets/blob.bin") {
                    corrupt(url, at: Int(src.offset + e.size - 1000))
                    return
                }
                try? src.skip(e.size + Int64(Tar.padding(e.size)))
            }
        })
        let report = await w.engine(cap: 1_000_000, hooks: hooks).offload([w.projectCandidate(p)], execute: true)
        guard case .failed? = report.results.first?.status else { Issue.record("not failed: \(String(describing: report.results.first?.status))"); return }
        try expectUntouched(w, p, before: before)
    }

    @Test func writeFailureMidCopyLeavesTheOriginal() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        let hooks = OffloadEngine.Hooks(writeFault: { $0 > 2_000_000 ? .io("simulated write error (EIO)") : nil })
        let report = await w.engine(hooks: hooks).offload([w.projectCandidate(p)], execute: true)
        guard case .failed(let msg)? = report.results.first?.status else { Issue.record("not failed"); return }
        #expect(msg.contains("simulated write error"))
        #expect(OffloadLayout.partials(in: w.nas).isEmpty)
        try expectUntouched(w, p, before: before)
    }

    @Test func shareDisappearingMidCopyLeavesTheOriginalAndAMarkedPartial() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        let engine = w.engine()
        w.probe.unmount(afterChecks: 6)  // a few checks pass, then the share is "gone" during the copy
        let report = await engine.offload([w.projectCandidate(p)], execute: true)
        guard case .failed(let msg)? = report.results.first?.status else { Issue.record("not failed"); return }
        #expect(msg.contains("went away"))
        #expect(report.results.first?.partialNote?.contains("marked as incomplete") == true)
        // The incomplete copy can't be removed while the share is gone; it's recognisable as partial.
        #expect(OffloadLayout.partials(in: w.nas).count == 1)
        #expect(OffloadLayout.manifests(in: w.nas).isEmpty)
        try expectUntouched(w, p, before: before)
    }

    @Test func cancellationLeavesTheOriginalAndRemovesThePartial() async throws {
        let w = try World()
        let p = try w.project()
        let before = try SourceTree.walk(p).nodes
        let hooks = OffloadEngine.Hooks(writeFault: { written in
            if written > 1_000_000 { withUnsafeCurrentTask { $0?.cancel() } }
            return nil
        })
        let engine = w.engine(hooks: hooks)
        let c = w.projectCandidate(p)
        let report = await Task { await engine.offload([c, c], execute: true) }.value
        #expect(report.results.map(\.status) == [.cancelled, .cancelled])
        #expect(OffloadLayout.partials(in: w.nas).isEmpty)
        try expectUntouched(w, p, before: before)
    }

    @Test func originalChangedDuringCopyIsKept() async throws {
        let w = try World()
        let p = try w.project()
        // Edited (different size) but back-dated, so the project still counts as stale and only the re-walk notices.
        let hooks = OffloadEngine.Hooks(afterPayloadWritten: { _ in
            let main = p.appending(path: "src/main.rs")
            try? Data("edited".utf8).write(to: main)
            OffloadEngine.setTimes(main.path, Date(timeIntervalSinceNow: -86400 * 200))
        })
        let report = await w.engine(hooks: hooks).offload([w.projectCandidate(p)], execute: true)
        let r = try #require(report.results.first)
        #expect(r.status == .offloaded(trashed: false))
        guard case .kept(let why)? = r.record?.original else { Issue.record("expected kept"); return }
        #expect(why.contains("changed"))
        #expect(FileManager.default.fileExists(atPath: p.path))
        #expect(w.remover.trashed.isEmpty)
    }

    // MARK: Revalidation

    @Test func onlyThingsMajorTomWouldOfferAreOffloaded() async throws {
        let w = try World()
        let p = try w.project()
        let engine = w.engine()
        // Not produced by any rule.
        let stray = try w.fx.file("Library/Preferences/com.example.plist", bytes: 100)
        let fake = OffloadCandidate(kind: .file, path: stray, displayName: "x", ruleID: "large-files")
        // Active project (recent change).
        let active = try w.project("active")
        try w.fx.file("src/new.rs", bytes: 10, in: active)
        // Pinned project.
        w.settings.pinnedProjects = [p.path]
        let pinnedEngine = w.engine()
        // Symlinked "project".
        let link = w.fx.home.appending(path: "WebstormProjects/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: w.fx.root)
        let report = await engine.offload([fake, w.projectCandidate(active), w.projectCandidate(link)], execute: true)
        for r in report.results {
            guard case .skipped = r.status else { Issue.record("\(r.candidate.path.path) was not refused: \(r.status)"); continue }
        }
        let pinned = await pinnedEngine.offload([w.projectCandidate(p)], execute: true)
        #expect(pinned.results.first?.status == .skipped("refused: project is pinned"))
        #expect(w.nasFiles().isEmpty)
        #expect(w.remover.trashed.isEmpty)
    }

    @Test func candidatesAreStaleProjectsArchivesAndColdFiles() async throws {
        let w = try World()
        try w.project()
        try w.project("fresh")
        try w.fx.file("WebstormProjects/fresh/src/today.rs", bytes: 10)
        try w.fx.userFile("Movies/old-master.mov", mb: 2, daysAgo: 400)
        try w.fx.userFile("Movies/new-master.mov", mb: 2, daysAgo: 3)
        try w.fx.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 100)
        let all = await w.engine().candidates()
        let names = Set(all.map(\.path.lastPathComponent))
        #expect(names.contains("rusty"))
        #expect(names.contains("App.xcarchive"))
        #expect(names.contains("old-master.mov"))
        #expect(!names.contains("fresh"))
        #expect(!names.contains("new-master.mov"))
        #expect(all.allSatisfy { $0.size != nil })
    }

    // MARK: Restore safety

    @Test func restoreNeverOverwritesAndCanGoElsewhere() async throws {
        let w = try World()
        let p = try w.project()
        let engine = w.engine()
        let record = try #require(await engine.offload([w.projectCandidate(p)], execute: true).results.first?.record)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try Data("new work".utf8).write(to: p.appending(path: "keep.txt"))
        let blocked = await engine.restore(record, execute: true)
        #expect(blocked.error == .alreadyExists(p.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.path) == ["keep.txt"])

        let elsewhere = try w.fx.dir("Restored")
        let moved = await engine.restore(record, into: elsewhere, execute: true)
        #expect(moved.succeeded)
        try expectIdentical(w.trash.appending(path: "rusty"), elsewhere.appending(path: "rusty"), xattrs: true)
        #expect(FileManager.default.fileExists(atPath: record.manifest.payloadPath))
    }

    @Test func restoreRefusesWhenTheShareIsGoneOrTheCopyIsDamaged() async throws {
        let w = try World()
        let p = try w.project()
        let engine = w.engine()
        let record = try #require(await engine.offload([w.projectCandidate(p)], execute: true).results.first?.record)
        w.probe.mounted = false
        let r1 = await engine.restore(record, execute: true)
        if case .notMounted? = r1.error {} else { Issue.record("expected notMounted, got \(String(describing: r1.error))") }
        #expect(!FileManager.default.fileExists(atPath: p.path))

        w.probe.mounted = true
        corrupt(URL(filePath: record.manifest.payloadPath), at: 2000)
        let r2 = await engine.restore(record, execute: true)
        if case .verification? = r2.error {} else { Issue.record("expected verification error, got \(String(describing: r2.error))") }
        #expect(!FileManager.default.fileExists(atPath: p.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.deletingLastPathComponent().path)
            .allSatisfy { !$0.hasPrefix(".majortom-restore") })
    }

    @Test func archivesWithUnsafePathsAreRejected() throws {
        var root: String?
        #expect(throws: OffloadError.self) { try OffloadEngine.relativePath("x/../../etc/passwd", rootName: &root) }
        root = nil
        #expect(throws: OffloadError.self) { try OffloadEngine.relativePath("/etc/passwd", rootName: &root) }
        root = nil
        #expect(try OffloadEngine.relativePath("rusty/", rootName: &root) == "")
        #expect(throws: OffloadError.self) { try OffloadEngine.relativePath("other/file", rootName: &root) }
    }

    @Test func smbSafeNames() {
        #expect(SMBName.safe("a:b*c?d\"e<f>g|h\\i") == "a_b_c_d_e_f_g_h_i")
        #expect(SMBName.safe("trailing. . ") == "trailing")
        #expect(SMBName.safe(".hidden") == "_hidden")
        #expect(SMBName.safe("con.txt") == "_con.txt")
        #expect(SMBName.safe("") == "item")
        let long = SMBName.safe(String(repeating: "ä", count: 200) + ".mov")
        #expect(long.utf8.count <= 120 && long.hasSuffix(".mov"))
        #expect(SMBName.safe("Cafe\u{301}") == "Caf\u{E9}")
        #expect(SMBName.timestamp(Date(timeIntervalSince1970: 0)) == "19700101-000000Z")
    }

    @Test func paxHeadersRoundTripLongNamesAndAttributes() throws {
        let fx = try Fixture()
        let path = fx.root.appending(path: "t.tar").path
        let name = "root/" + String(repeating: "ü", count: 120) + "/f"
        let sink = try PayloadSink(path: path) { _ in }
        try sink.append(Tar.headers(name: name, type: .file, size: 3, mode: 0o640, mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                    xattrs: [("user.a", Data([0, 10, 61, 255]))]))
        try sink.append([1, 2, 3] + [UInt8](repeating: 0, count: 509))
        try sink.append(Tar.end())
        _ = try sink.finish()
        let src = try PayloadSource(path: path)
        let e = try #require(try Tar.next(src))
        #expect(e.name == name)
        #expect(e.size == 3 && e.mode == 0o640 && e.mtime == 1_700_000_000)
        #expect(e.xattrs.first?.name == "user.a" && e.xattrs.first?.value == Data([0, 10, 61, 255]))
        try src.skip(512)
        #expect(try Tar.next(src) == nil)
    }
}

// MARK: Helpers

/// Flips one byte of a file in place.
func corrupt(_ url: URL, at offset: Int) {
    guard let h = try? FileHandle(forUpdating: url) else { return }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(offset))
    let b = (try? h.read(upToCount: 1))?.first ?? 0
    try? h.seek(toOffset: UInt64(offset))
    try? h.write(contentsOf: Data([b ^ 0xFF]))
}

/// Same tree: names, kinds, contents, symlink targets, permissions, modification dates (to the second) and,
/// optionally, extended attributes.
func expectIdentical(_ a: URL, _ b: URL, xattrs: Bool) throws {
    let ta = try SourceTree.walk(a).nodes, tb = try SourceTree.walk(b).nodes
    #expect(ta.map(\.rel) == tb.map(\.rel))
    for (x, y) in zip(ta, tb) {
        #expect(x.type == y.type && x.size == y.size && x.linkTarget == y.linkTarget && x.mode == y.mode, "\(x.rel)")
        #expect(abs(x.modified.timeIntervalSince(y.modified)) < 1, "\(x.rel) date")
        let pa = x.rel.isEmpty ? a.path : a.path + "/" + x.rel
        let pb = y.rel.isEmpty ? b.path : b.path + "/" + y.rel
        if x.type == .file {
            #expect(try Data(contentsOf: URL(filePath: pa)) == Data(contentsOf: URL(filePath: pb)), "\(x.rel) content")
        }
        if xattrs {
            #expect(XAttr.digest(XAttr.read(pa)) == XAttr.digest(XAttr.read(pb)), "\(x.rel) xattrs")
        }
    }
}
