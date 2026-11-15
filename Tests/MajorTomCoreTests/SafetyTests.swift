import Foundation
import Testing
@testable import MajorTomCore

@Suite("Path validation")
struct PathValidationTests {
    func validator(_ f: Fixture, projectRoots: [URL] = []) -> PathValidator {
        PathValidator(home: f.home, allowedSystemRoots: [], projectRoots: projectRoots)
    }

    @Test func acceptsItemInsideBase() throws {
        let f = try Fixture()
        let item = try f.file("cache/a/blob")
        let v = validator(f)
        try v.validate(item.deletingLastPathComponent(), bases: [f.home.appending(path: "cache")])
        try v.validate(f.home.appending(path: "cache"), bases: [f.home.appending(path: "cache")])
    }

    @Test func refusesProtectedLocations() throws {
        let f = try Fixture()
        for rel in ["Library", "Documents", "Desktop", "Downloads", "Library/Caches", "Library/Application Support"] {
            try f.dir(rel)
        }
        let v = validator(f)
        #expect(throws: PathValidationError.outsideAllowedRoots(f.home.path)) {
            try v.validate(f.home, bases: [f.home])
        }
        for rel in ["Library", "Documents", "Desktop", "Downloads", "Library/Caches", "Library/Application Support"] {
            let url = f.home.appending(path: rel)
            #expect(throws: PathValidationError.protectedLocation(url.path)) {
                try v.validate(url, bases: [f.home])
            }
        }
    }

    @Test func refusesOutsideHomeAndDotDot() throws {
        let f = try Fixture()
        let outside = try f.file("elsewhere/x", in: f.root)
        let v = validator(f)
        #expect(throws: PathValidationError.self) { try v.validate(outside, bases: [f.root]) }
        let sneaky = URL(filePath: f.home.path + "/cache/../../elsewhere/x")
        #expect(throws: PathValidationError.self) { try v.validate(sneaky, bases: [f.home.appending(path: "cache")]) }
        #expect(throws: PathValidationError.self) { try v.validate(URL(filePath: "/"), bases: [URL(filePath: "/")]) }
    }

    @Test func refusesOutsideRuleBase() throws {
        let f = try Fixture()
        let other = try f.file("other/thing")
        #expect(throws: PathValidationError.outsideRuleBase(other.path)) {
            try validator(f).validate(other, bases: [f.home.appending(path: "cache")])
        }
    }

    @Test func refusesProjectRoots() throws {
        let f = try Fixture()
        let repo = try f.dir("cache/repo")
        try f.dir("cache/repo/.git")
        let configured = try f.dir("cache/WebstormProjects")
        #expect(throws: PathValidationError.projectRoot(repo.path)) {
            try validator(f).validate(repo, bases: [f.home.appending(path: "cache")])
        }
        #expect(throws: PathValidationError.projectRoot(configured.path)) {
            try validator(f, projectRoots: [configured]).validate(configured, bases: [f.home.appending(path: "cache")])
        }
    }

    @Test func refusesSymlinkEscapingBase() throws {
        let f = try Fixture()
        let precious = try f.dir("precious")
        try f.file("precious/data.txt")
        try f.dir("cache")
        try f.symlink("cache/link", to: precious)
        let viaLink = f.home.appending(path: "cache/link/data.txt")
        #expect(throws: PathValidationError.symlinkEscape(viaLink.path)) {
            try validator(f).validate(viaLink, bases: [f.home.appending(path: "cache")])
        }
    }

    @Test func refusesBaseThatIsSymlinkOutOfHome() throws {
        let f = try Fixture()
        let external = try f.dir("external-cache", in: f.root)
        try f.file("external-cache/blob", in: f.root)
        try f.symlink("cache", to: external)
        let item = f.home.appending(path: "cache/blob")
        #expect(throws: PathValidationError.symlinkEscape(item.path)) {
            try validator(f).validate(item, bases: [f.home.appending(path: "cache")])
        }
    }

    @Test func allowsItemThatIsItselfASymlink() throws {
        // Removing a symlink only removes the link, never its target.
        let f = try Fixture()
        let target = try f.file("precious/data.txt")
        try f.dir("cache")
        try f.symlink("cache/link", to: target)
        try validator(f).validate(f.home.appending(path: "cache/link"), bases: [f.home.appending(path: "cache")])
    }

    @Test func refusesMissing() throws {
        let f = try Fixture()
        try f.dir("cache")
        let ghost = f.home.appending(path: "cache/ghost")
        #expect(throws: PathValidationError.missing(ghost.path)) {
            try validator(f).validate(ghost, bases: [f.home.appending(path: "cache")])
        }
    }
}

@Suite("Clean engine")
struct CleanEngineTests {
    func engine(_ f: Fixture, rules: [Rule], runner: FakeRunner = FakeRunner()) -> CleanEngine {
        CleanEngine(rules: rules, context: f.context(runner: runner), history: f.historyLog, freeSpace: { 1_000 })
    }

    @Test func dryRunIsTheDefault() async throws {
        let f = try Fixture()
        let a = try f.file("cache/a", bytes: 10_000)
        let b = try f.file("cache/b/inner", bytes: 10_000)
        let e = engine(f, rules: [testRule()])
        let report = await e.clean([CleanRequest(ruleID: "test-cache", itemIDs: [a.path, b.deletingLastPathComponent().path])])
        #expect(report.dryRun)
        #expect(report.outcomes.allSatisfy { $0.status == .wouldClean })
        #expect(f.exists(a) && f.exists(b))
        #expect(f.historyLog.entries().isEmpty)

        let action = await e.runAction(ruleID: "test-cache", actionID: "nope")
        #expect(action.dryRun)
    }

    @Test func executeDeletesAndLogsHistory() async throws {
        let f = try Fixture()
        let a = try f.file("cache/a", bytes: 10_000)
        let keep = try f.file("cache/keep", bytes: 10)
        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [a.path])], sizes: [a.path: 10_000], execute: true)
        #expect(!report.dryRun)
        #expect(report.outcomes.first?.status == .cleaned)
        #expect(!f.exists(a))
        #expect(f.exists(keep))
        let history = f.historyLog.entries()
        #expect(history.count == 1)
        #expect(history.first?.items.first?.path == a.path)
        #expect(history.first?.estimatedBytes == 10_000)
        #expect(history.first?.reclaimedBytes == 0)  // injected free-space probe didn't change
    }

    @Test func refusesItemsNotProducedByResolver() async throws {
        let f = try Fixture()
        try f.file("cache/a")
        let precious = try f.file("Documents/thesis.txt")
        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [precious.path])], execute: true)
        guard case .skipped = report.outcomes.first?.status else {
            Issue.record("expected skip, got \(String(describing: report.outcomes.first?.status))"); return
        }
        #expect(f.exists(precious))
        #expect(f.historyLog.entries().isEmpty)
    }

    @Test func refusesSymlinkEscapeAtCleanTime() async throws {
        let f = try Fixture()
        let precious = try f.dir("precious")
        let data = try f.file("precious/data.txt")
        try f.dir("cache")
        try f.symlink("cache/link", to: precious)
        // A buggy resolver that hands out a path *through* the symlink.
        let rule = testRule(extra: { ctx in [Item(displayName: "evil", path: ctx.path("cache/link/data.txt"))] })
        let report = await engine(f, rules: [rule])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [f.home.appending(path: "cache/link/data.txt").path])], execute: true)
        guard case .skipped(let why) = report.outcomes.first?.status else {
            Issue.record("expected refusal"); return
        }
        #expect(why.contains("symlink"))
        #expect(f.exists(data))
    }

    @Test func neverTouchesProtectedOrReportOnly() async throws {
        let f = try Fixture()
        let p = try f.file("cache/protected")
        let r = try f.file("cache/report")
        let rule = Rule(id: "t", title: "t", category: .system, tier: .safe, impact: "", recovery: "", regenCost: "",
                        method: .delete, baseDirectories: { [$0.path("cache")] },
                        resolve: { ctx in [
                            Item(displayName: "p", path: ctx.path("cache/protected"), isProtected: true),
                            Item(displayName: "r", path: ctx.path("cache/report"), methodOverride: .reportOnly),
                        ] })
        let report = await engine(f, rules: [rule]).clean([CleanRequest(ruleID: "t", itemIDs: [p.path, r.path])], execute: true)
        #expect(report.outcomes.allSatisfy { if case .skipped = $0.status { true } else { false } })
        #expect(f.exists(p) && f.exists(r))
    }

    @Test func commandItemsOnlyRunOnExecute() async throws {
        let f = try Fixture()
        let runner = FakeRunner(["tool clean x": ""])
        let rule = Rule(id: "cmd", title: "cmd", category: .system, tier: .safe, impact: "", recovery: "", regenCost: "",
                        method: .command(["tool", "clean", "x"]), baseDirectories: { _ in [] },
                        resolve: { _ in [Item(id: "x", displayName: "x", path: nil)] })
        let e = engine(f, rules: [rule], runner: runner)
        _ = await e.clean([CleanRequest(ruleID: "cmd", itemIDs: ["x"])])
        #expect(runner.recordedCalls.isEmpty)
        let report = await e.clean([CleanRequest(ruleID: "cmd", itemIDs: ["x"])], execute: true)
        #expect(runner.recordedCalls == [["tool", "clean", "x"]])
        #expect(report.outcomes.first?.status == .cleaned)
    }

    @Test func trashMethodMovesReviewItemsToTrash() async throws {
        // Only checks the dry-run plan: a real trashItem would put fixture files in the user's actual Trash.
        let f = try Fixture()
        let a = try f.file("cache/a")
        let report = await engine(f, rules: [testRule(tier: .review, method: .trash)])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [a.path])])
        #expect(report.outcomes.first?.method == .trash)
        #expect(report.outcomes.first?.status == .wouldClean)
    }
}

@Suite("Disk sizer")
struct DiskSizerTests {
    @Test func countsHardLinksOnce() async throws {
        let f = try Fixture()
        let original = try f.file("store/blob", bytes: 1_000_000)
        try f.dir("project/node_modules")
        let link = f.home.appending(path: "project/node_modules/blob")
        try FileManager.default.linkItem(at: original, to: link)

        let tracker = InodeTracker()
        let store = try #require(DiskSizer.sizeSync(of: f.home.appending(path: "store"), tracker: tracker))
        let project = try #require(DiskSizer.sizeSync(of: f.home.appending(path: "project"), tracker: tracker))
        #expect(store.allocatedBytes >= 1_000_000)
        #expect(project.allocatedBytes < 100_000)  // just directory entries

        // A fresh tracker counts it again.
        let again = try #require(DiskSizer.sizeSync(of: f.home.appending(path: "project"), tracker: InodeTracker()))
        #expect(again.allocatedBytes >= 1_000_000)
    }

    @Test func doesNotFollowSymlinks() throws {
        let f = try Fixture()
        let big = try f.file("big/blob", bytes: 2_000_000)
        try f.dir("cache")
        try f.symlink("cache/link", to: big.deletingLastPathComponent())
        let r = try #require(DiskSizer.sizeSync(of: f.home.appending(path: "cache"), tracker: InodeTracker()))
        #expect(r.allocatedBytes < 100_000)
    }

    @Test func parallelWalkMatchesTotal() throws {
        let f = try Fixture()
        // Wide tree so the frontier expansion kicks in.
        for i in 0..<60 { for j in 0..<3 { try f.file("tree/d\(i)/e\(j)/f", bytes: 8192) } }
        let r = try #require(DiskSizer.sizeSync(of: f.home.appending(path: "tree"), tracker: InodeTracker()))
        #expect(r.fileCount == 1 + 60 + 180 + 180)
        #expect(r.allocatedBytes >= 180 * 8192)
    }

    @Test func missingPathIsNil() {
        #expect(DiskSizer.sizeSync(of: URL(filePath: "/nonexistent/\(UUID())"), tracker: InodeTracker()) == nil)
    }
}
