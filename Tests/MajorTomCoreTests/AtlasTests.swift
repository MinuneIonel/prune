import Foundation
import Testing
@testable import MajorTomCore

@Suite("Space map") struct AtlasTests {
    @Test func namesTellKindsAndOrigins() {
        #expect(FileClassifier.kind(ofFile: "DSC_0412.ARW") == .photo)
        #expect(FileClassifier.kind(ofFile: "tunnel.MOV") == .video)
        #expect(FileClassifier.kind(ofFile: "Starman.drp") == .project)
        #expect(FileClassifier.kind(ofFile: "main.swift") == .code)
        #expect(FileClassifier.kind(ofFile: "README") == .other)
        #expect(FileClassifier.origin(ofFile: "DSC_0412.ARW")?.name == "Sony camera")
        #expect(FileClassifier.origin(ofFile: "2026-11-15 19-33-50.mov") == .obs)
        #expect(FileClassifier.origin(ofFile: "2026-11-15 notes.mov") == nil)
        #expect(FileClassifier.origin(ofFile: "Screen Recording 2026-01-02 at 10.00.00.mov") == .screenCapture)
        #expect(FileClassifier.origin(ofFile: "A001C003_250412.braw")?.name == "Blackmagic camera")
        #expect(FileClassifier.origin(ofFile: "C0001.MP4") == .camera)
        #expect(FileClassifier.origin(ofFile: "Festival set.avc") == .resolume)
        #expect(FileClassifier.origin(ofFile: "holiday.jpg") == nil)
        #expect(FileClassifier.directory(name: "CacheClip", homeRelative: "Movies/CacheClip").origin == .resolve)
        #expect(FileClassifier.directory(name: "node_modules", homeRelative: nil).kind == .cache)
        #expect(FileClassifier.directory(name: "com.blackmagic-design.DaVinciResolve",
                                         homeRelative: "Library/Application Support/com.blackmagic-design.DaVinciResolve").origin == .resolve)
        #expect(FileClassifier.directory(name: "com.acme.Widget", homeRelative: "Library/Caches/com.acme.Widget").origin?.name == "Widget")
    }

    @Test func scanAddsUpAndAttributes() throws {
        let f = try Fixture()
        try f.file("Shoots/a/DSC_0001.ARW", bytes: 300_000)
        try f.file("Shoots/a/DSC_0002.ARW", bytes: 300_000)
        try f.file("Movies/CacheClip/x/cache.bin", bytes: 400_000)
        try f.file("Movies/2026-11-15 19-33-50.mov", bytes: 200_000)
        try f.file("Code/app/node_modules/lib/index.js", bytes: 100_000)
        try f.file("Code/app/main.swift", bytes: 8_000)
        for i in 0..<5 { try f.file("Notes/n\(i).txt", bytes: 4096) }
        // A hard link must not be counted twice.
        try FileManager.default.linkItem(at: f.home.appending(path: "Shoots/a/DSC_0001.ARW"),
                                         to: f.home.appending(path: "Shoots/a/DSC_0001 copy.ARW"))

        let map = try #require(SpaceMapScanner(root: f.home, home: f.home, keepBytes: 50_000).scan())
        let root = map.root
        #expect(root.size == root.children.reduce(0) { $0 + $1.size } + root.smallBytes)
        #expect(root.size == FileKind.allCases.reduce(0) { $0 + root.bytes(of: $1) })
        #expect(root.bytes(of: .photo) >= 600_000 && root.bytes(of: .photo) < 700_000)
        #expect(root.bytes(of: .cache) >= 500_000)          // CacheClip + node_modules, whatever the extensions say
        #expect(root.bytes(of: .video) >= 200_000 && root.bytes(of: .video) < 300_000)
        #expect(root.children.first { $0.name == "Notes" } == nil && root.smallCount >= 1)   // folded: too small
        #expect(map.node(at: f.home.appending(path: "Shoots/a").path(percentEncoded: false))?.kind == .photo)
        let cache = try #require(map.node(at: f.home.appending(path: "Movies/CacheClip").path(percentEncoded: false)))
        #expect(cache.origin == .resolve && cache.kind == .cache)

        let origins = Dictionary(uniqueKeysWithValues: map.origins.map { ($0.origin.id, $0) })
        #expect(origins["camera-sony"]?.fileCount == 3)
        #expect((origins["camera-sony"]?.bytes ?? 0) < 700_000)
        #expect(origins["resolve"] != nil && origins["obs"] != nil && origins["npm"] != nil)
        #expect(map.origins.map(\.bytes) == map.origins.map(\.bytes).sorted(by: >))
    }

    @Test func scanOfAMissingFolderIsNil() throws {
        let f = try Fixture()
        #expect(SpaceMapScanner(root: f.home.appending(path: "nope"), home: f.home).scan() == nil)
    }

    @Test func mediaRulesListOnlyDerivedFiles() async throws {
        let f = try Fixture()
        try f.file("Movies/CacheClip/a1/frame.dvcc")
        try f.file("Movies/Resolve Project Backups/p.drp")
        try f.file("Library/Application Support/Adobe/Common/Media Cache Files/x.pek")
        try f.file("Pictures/Work.cocatalog/Cache/Proxies/a.cop")
        try f.file("Pictures/Work.cocatalog/Work.cocatalogdb")
        try f.file("Pictures/Work.cocatalog/Originals/a.arw")
        let ctx = f.context()
        let resolve = try await MediaRules.resolveRenderCache.resolve(ctx)
        #expect(resolve.map(\.displayName) == ["a1"])
        #expect(try await MediaRules.adobeMediaCache.resolve(ctx).map(\.displayName) == ["Media Cache Files"])
        let c1 = try await MediaRules.captureOnePreviews.resolve(ctx)
        #expect(c1.count == 1 && c1[0].path?.lastPathComponent == "Cache")
    }
}
