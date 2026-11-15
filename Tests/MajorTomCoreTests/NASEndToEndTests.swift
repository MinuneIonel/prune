import Darwin
import Foundation
import Testing
@testable import MajorTomCore

/// Opt-in round trip against the real NAS share:
///
///     MAJORTOM_NAS_E2E=/Volumes/<share>/_devtest swift test --filter NASEndToEnd
///
/// The folder must be called `_devtest`, must not exist yet, and its parent must be a mounted network share.
///
/// Source data is generated in a temp folder; the only place written on the share is the given `_devtest` folder,
/// which is removed at the end. Never touches anything else on the NAS or on this Mac.
@Suite("NAS end-to-end (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["MAJORTOM_NAS_E2E"] != nil))
struct NASEndToEndTests {
    static let requiredName = "_devtest"

    @Test func realShareRoundTripAndAFailedRun() async throws {
        let destPath = try #require(ProcessInfo.processInfo.environment["MAJORTOM_NAS_E2E"])
        let dest = URL(filePath: destPath, directoryHint: .isDirectory).standardizedFileURL
        try #require(dest.lastPathComponent == Self.requiredName, "only a folder named \(Self.requiredName) may be used")
        let shareCheck = DestinationCheck.check(dest.deletingLastPathComponent(), probe: LiveVolumeProbe())
        try #require(shareCheck.isReady, "share not mounted: \(shareCheck.message)")
        try #require(!FileManager.default.fileExists(atPath: destPath), "\(destPath) already exists; remove it first")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        defer {
            if dest.lastPathComponent == Self.requiredName { try? FileManager.default.removeItem(at: dest) }
        }
        let fx = try Fixture()
        let remover = RecordingRemover(trashFolder: fx.root.appending(path: "Trash"))
        var settings = fx.fileSettings
        settings.largeFileThresholdMB = 50
        let engine = OffloadEngine(destination: dest, probe: LiveVolumeProbe(), context: fx.context(settings: settings),
                                   rules: FilesRules.all, git: FakeRunner(),
                                   store: OffloadStore(directory: fx.root.appending(path: "offloads")),
                                   remover: remover, history: fx.historyLog)

        // Fixture source: a project with ~2,000 small files (incl. a fake .git), odd names, symlinks, an xattr and a
        // 192 MB file; and a 160 MB cold movie (copied as a plain file).
        let project = try makeProject(fx, name: "e2e project: alpha", bigMB: 192)
        let movie = try randomFile(fx.home.appending(path: "Movies/cold master?.mov"), mb: 160)
        try FileTimes.set(movie, modified: Date(timeIntervalSinceNow: -400 * 86400), added: Date(timeIntervalSinceNow: -400 * 86400))
        let candidates = await engine.candidates(projects: [])
        let movieCandidate = try #require(candidates.first { $0.path == movie.standardizedFileURL })
        let projectCandidate = OffloadCandidate(kind: .project, path: project, displayName: project.lastPathComponent)
        let start = Date()
        let report = await engine.offload([projectCandidate, movieCandidate], execute: true)
        let elapsed = Date().timeIntervalSince(start)
        for r in report.results {
            #expect(r.status == .offloaded(trashed: true), "\(r.candidate.displayName): \(r.status)")
            let mbps = Double(r.payloadBytes) / 1_000_000 / max(0.001, r.copySeconds)
            print("NAS-E2E offload \(r.candidate.displayName): \(ByteFormat.string(r.payloadBytes)) copied in \(String(format: "%.1f", r.copySeconds)) s = \(String(format: "%.0f", mbps)) MB/s (\(r.record?.manifest.format.rawValue ?? "?"))")
        }
        let total = report.results.reduce(Int64(0)) { $0 + $1.payloadBytes }
        print("NAS-E2E batch: \(ByteFormat.string(total)) copied + verified in \(String(format: "%.1f", elapsed)) s")
        let records = report.results.compactMap(\.record)
        #expect(records.count == 2)
        #expect(OffloadLayout.partials(in: dest).isEmpty)
        #expect(OffloadLayout.manifests(in: dest).count == 2)

        // Restore both and compare byte for byte with the trashed originals.
        for record in records {
            let t0 = Date()
            let restored = await engine.restore(record, execute: true)
            #expect(restored.succeeded, "\(record.manifest.displayName): \(String(describing: restored.error))")
            print("NAS-E2E restore \(record.manifest.displayName): \(ByteFormat.string(restored.bytes)) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, xattr failures \(restored.xattrFailures)")
            let trashed = fx.root.appending(path: "Trash").appending(path: URL(filePath: record.manifest.sourcePath).lastPathComponent)
            try expectIdentical(trashed, URL(filePath: record.manifest.sourcePath), xattrs: true)
            let cmp = Process()
            cmp.executableURL = URL(filePath: "/usr/bin/diff")
            cmp.arguments = ["-r", "--no-dereference", trashed.path, record.manifest.sourcePath]
            try cmp.run()
            cmp.waitUntilExit()
            #expect(cmp.terminationStatus == 0, "diff -r found differences")
        }

        // A deliberately failed run: the NAS copy is corrupted before verification.
        let failing = try makeProject(fx, name: "e2e-fail", bigMB: 24)
        let before = try SourceTree.walk(failing).nodes
        var broken = engine
        broken.hooks.afterPayloadWritten = { url in corrupt(url, at: 50_000) }
        let failed = await broken.offload([OffloadCandidate(kind: .project, path: failing, displayName: "e2e-fail")], execute: true)
        let f = try #require(failed.results.first)
        print("NAS-E2E failed run: \(f.status) — \(f.partialNote ?? "")")
        guard case .failed(let msg) = f.status else { Issue.record("expected failure"); return }
        #expect(msg.contains("verification failed"))
        #expect(SourceTree.differences(before, try SourceTree.walk(failing).nodes).isEmpty)
        #expect(!remover.trashed.contains { $0.path == failing.path })
        #expect(OffloadLayout.partials(in: dest).isEmpty)
        #expect(OffloadLayout.manifests(in: dest).count == 2)
    }

    func makeProject(_ fx: Fixture, name: String, bigMB: Int) throws -> URL {
        let p = try fx.dir("WebstormProjects/\(name)")
        for i in 0..<1500 { try fx.file("src/module\(i / 100)/file \(i).ts", bytes: 200 + i % 900, in: p) }
        for i in 0..<500 { try fx.file(".git/objects/\(String(format: "%02x", i % 256))/obj\(i)", bytes: 100 + i, in: p) }
        try fx.file("weird/a:b*c?.txt", bytes: 10, in: p)
        try fx.file("weird/trailing dot.", bytes: 10, in: p)
        try fx.file("weird/Ünïcødé.md", bytes: 10, in: p)
        try fx.file(String(repeating: "long-folder-name-segment/", count: 14) + "deep.txt", bytes: 10, in: p)
        _ = try randomFile(p.appending(path: "assets/big.bin"), mb: bigMB)
        let tagged = p.appending(path: "src/module0/file 0.ts").path
        _ = setxattr(tagged, "com.example.tag", "orbit", 5, 0, XATTR_NOFOLLOW)
        let longAgo = Date(timeIntervalSinceNow: -86400 * 200)
        try FixtureWorld.setModificationDates(in: p, to: longAgo)
        let link = p.appending(path: "current").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "src/module0")
        OffloadEngine.setTimes(link, longAgo)
        OffloadEngine.setTimes(p.path, longAgo)
        return p
    }

    func randomFile(_ url: URL, mb: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        var chunk = Data(count: 1_000_000)
        for _ in 0..<mb {
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try h.write(contentsOf: chunk)
        }
        return url
    }
}
