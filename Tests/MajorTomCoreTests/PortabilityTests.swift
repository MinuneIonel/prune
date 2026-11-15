import Foundation
import Testing
@testable import MajorTomCore

/// Another Mac: different folders, missing tools, no NAS. Everything here runs against an empty fixture home.
@Suite("Portability")
struct PortabilityTests {
    /// Every command "exists" but fails (Docker daemon stopped, xcrun with only the Command Line Tools, …).
    final class FailingRunner: CommandRunner, @unchecked Sendable {
        func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? {
            CommandResult(exitCode: 1, stdout: Data(), stderr: Data("error: tool unavailable\n".utf8))
        }
    }

    /// Every command succeeds with empty output.
    final class SilentRunner: CommandRunner, @unchecked Sendable {
        func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? {
            CommandResult(exitCode: 0, stdout: Data())
        }
    }

    // MARK: Rules with nothing installed

    @Test(arguments: ["absent", "failing", "silent"])
    func everyRuleFindsNothingInAnEmptyHome(tools: String) async throws {
        let f = try Fixture()
        let runner: any CommandRunner = switch tools {
        case "absent": FakeRunner()
        case "failing": FailingRunner()
        default: SilentRunner()
        }
        let ctx = f.context(runner: runner, environment: ["ANDROID_HOME": "/opt/android-sdk", "PATH": "/usr/bin:/bin"])
        #expect(ctx.settings.expandedProjectRoots(home: f.home).isEmpty)
        for rule in RuleCatalogue.all {
            let items = try await rule.resolve(ctx)
            #expect(items.isEmpty, "\(rule.id) found something with tools \(tools)")
            #expect(rule.actions(ctx, items).isEmpty, "\(rule.id) offers an action with nothing found")
        }
    }

    @Test func partialToolchainsListOnlyWhatIsThere() async throws {
        let f = try Fixture()
        // Android Studio installed but never used for an emulator; ANDROID_HOME outside the home is ignored.
        try f.file("Library/Android/sdk/platforms/android-35/android.jar")
        // pnpm used once, store elsewhere / not created yet; Homebrew installed (any prefix) with no downloads yet.
        try f.dir("Library/pnpm")
        try f.dir("Library/Caches")
        // nvm without a default alias; rustup with no settings file.
        try f.file(".nvm/versions/node/v22.11.0/bin/node")
        try f.file(".rustup/toolchains/stable-x86_64-apple-darwin/bin/rustc")
        let ctx = f.context(environment: ["ANDROID_HOME": "/opt/android-sdk"])

        let sdk = try await AndroidRules.sdk.resolve(ctx)
        #expect(sdk.map(\.displayName) == ["Platform android-35"])
        #expect(try await AndroidRules.avds.resolve(ctx).isEmpty)
        let pnpm = try await JavaScriptRules.pnpm.resolve(ctx)
        #expect(pnpm.isEmpty && JavaScriptRules.pnpm.actions(ctx, pnpm).isEmpty)
        let brew = try await PackageManagerRules.homebrew.resolve(ctx)
        #expect(brew.isEmpty && PackageManagerRules.homebrew.actions(ctx, brew).isEmpty)
        let node = try await JavaScriptRules.nvm.resolve(ctx)
        #expect(node.count == 1)
        let rust = try await PackageManagerRules.cargo.resolve(ctx)
        #expect(rust.map(\.displayName) == ["toolchain stable-x86_64-apple-darwin"])
    }

    // MARK: Developer tools stubs

    @Test func commandLineToolStubsCountAsMissingWithoutDeveloperTools() async throws {
        var runner = ProcessRunner(environment: ["PATH": "/usr/bin:/bin"])
        runner.searchPath = ["/usr/bin", "/bin"]
        runner.developerToolsInstalled = { false }
        #expect(runner.locate("git") == nil)
        #expect(runner.locate("xcrun") == nil)
        #expect(runner.locate("/usr/bin/git") == nil)
        #expect(await runner.run(["git", "--version"], timeout: 5) == nil)
        // Real system tools are unaffected.
        #expect(runner.locate("tmutil") != nil)
        runner.developerToolsInstalled = { true }
        #expect(runner.locate("git")?.path == "/usr/bin/git")
    }

    @Test func developerToolsDetectionHonoursDeveloperDir() throws {
        let f = try Fixture()
        let dev = try f.dir("Xcode-beta.app/Contents/Developer/usr/bin")
        let developerDir = dev.deletingLastPathComponent().deletingLastPathComponent().path
        #expect(DeveloperTools.installed(environment: ["DEVELOPER_DIR": developerDir]))
    }

    // MARK: Project roots

    @Test func projectRootsAreDetectedFromCommonFolders() throws {
        let f = try Fixture()
        #expect(ProjectRootDetector.detect(home: f.home).isEmpty)
        try f.dir("projects/app")          // lower case, as typed on disk
        try f.dir("Developer")
        try f.file("src", bytes: 10)       // a file, not a folder
        try f.dir("elsewhere/Code")
        try f.symlink("Code", to: f.home.appending(path: "elsewhere/Code"))  // symlinks aren't followed
        try f.dir("Documents/GitHub/repo")
        try f.dir("Documents/Code")        // not a candidate
        #expect(ProjectRootDetector.detect(home: f.home) == ["~/projects", "~/Developer", "~/Documents/GitHub"])

        var s = Settings()
        #expect(s.projectRootsAreAutomatic)
        #expect(s.expandedProjectRoots(home: f.home) == [
            f.home.appending(path: "projects"), f.home.appending(path: "Developer"), f.home.appending(path: "Documents/GitHub"),
        ])
        s.projectRoots = []
        #expect(s.expandedProjectRoots(home: f.home).isEmpty, "an explicit empty list means none, not detection")
        s.projectRoots = ["~/Work", "/Volumes/Data/src"]
        #expect(s.expandedProjectRoots(home: f.home) == [f.home.appending(path: "Work"), URL(filePath: "/Volumes/Data/src")])
    }

    @Test func projectScannerWithNoRootsFindsNothing() async throws {
        let f = try Fixture()
        let projects = await ProjectScanner(context: f.context(), git: FakeRunner()).discover()
        #expect(projects.isEmpty)
    }

    // MARK: Settings compatibility

    /// The settings file as written by the M1–M6 builds on the owner's Mac (no version, no offload destination).
    static let legacyFile = #"""
    {
      "disabledRuleIDs" : [ ], "ignoredPaths" : [ ], "ignoredProjects" : [ ], "launchAtLogin" : false,
      "lowSpaceNotifications" : false, "lowSpaceThresholdGB" : 20, "pinnedProjects" : [ ],
      "projectRoots" : [ "~\/WebstormProjects" ], "staleAfterDays" : 90, "weeklyRescan" : false
    }
    """#

    @Test func legacySettingsKeepTheirImplicitDestinationAndRoots() throws {
        let f = try Fixture()
        let store = SettingsStore(url: f.root.appending(path: "settings.json"))
        try Data(Self.legacyFile.utf8).write(to: store.url)
        let s = store.load()
        #expect(s.offloadDestination == Settings.legacyOffloadDestination)
        #expect(s.projectRoots == ["~/WebstormProjects"])
        #expect(!s.projectRootsAreAutomatic)
        #expect(s.ownBundleIDPrefixes == ["uk.co.tom-jordan."])
        #expect(s.version == Settings.currentVersion)
        // Saved again it stays the same (now explicit), and a cleared destination stays cleared.
        try store.save(s)
        #expect(store.load() == s)
        var cleared = s
        cleared.offloadDestination = nil
        try store.save(cleared)
        #expect(store.load().offloadDestination == nil)
    }

    @Test func freshSettingsHaveNoMachineSpecificDefaults() throws {
        let f = try Fixture()
        let store = SettingsStore(url: f.root.appending(path: "settings.json"))
        let s = store.load()
        #expect(s.offloadDestination == nil && s.offloadDestinationURL == nil)
        #expect(s.projectRoots == nil)
        try store.save(s)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("offloadDestination") && !text.contains("projectRoots"))
        #expect(store.load() == s)
        // A current-version file without a destination doesn't get the legacy one.
        try Data(#"{"version": 2, "staleAfterDays": 30}"#.utf8).write(to: store.url)
        #expect(store.load().offloadDestination == nil)
    }

    // MARK: Offload without a NAS

    @Test func offloadWithoutADestinationDoesNothing() async throws {
        let f = try Fixture()
        let engine = OffloadEngine(destination: nil, probe: FakeVolumeProbe(root: f.root), context: f.context(),
                                   rules: [], git: FakeRunner(), store: OffloadStore(directory: f.root.appending(path: "offloads")),
                                   remover: FolderTrashRemover(trashFolder: f.root.appending(path: "Trash")),
                                   history: f.historyLog)
        #expect(engine.checkDestination() == .notSet)
        #expect(!DestinationCheck.notSet.message.isEmpty)
        #expect(engine.importFromShare().isEmpty)
        #expect(engine.removeIncompleteCopies().removed == 0)
        let report = await engine.offload([], execute: true)
        #expect(report.destination == .notSet && report.results.isEmpty)
        #expect(await engine.candidates(projects: []).isEmpty)
    }

    // MARK: Own bundle-ID prefixes

    @Test func ownBundleIDPrefixesComeFromSettings() async throws {
        let f = try Fixture()
        let old = Date(timeIntervalSinceNow: -200 * 86400)
        for id in ["com.acme.notes", "com.acmetools.viewer", "uk.co.tom-jordan.majortom"] {
            let dir = try f.dir("Library/Application Support/\(id)")
            try f.file("state.db", in: dir)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appending(path: "state.db").path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }
        func orphans(_ prefixes: [String]) async throws -> [String] {
            var s = Settings()
            s.projectRoots = []
            s.ownBundleIDPrefixes = prefixes
            var ctx = f.context(settings: s)
            ctx.appSources = .only([f.home.appending(path: "Applications")])
            return try await OrphanedAppData.rule.resolve(ctx).map(\.id).sorted()
        }
        // Default: the owner's prefix is held back, so behaviour on the original Mac is unchanged.
        #expect(try await orphans(Settings().ownBundleIDPrefixes) == ["orphan:com.acme.notes", "orphan:com.acmetools.viewer"])
        // A prefix (with or without the trailing dot) matches whole components only.
        #expect(try await orphans(["com.acme"]) == ["orphan:com.acmetools.viewer", "orphan:uk.co.tom-jordan.majortom"])
        #expect(try await orphans([]).count == 3)
        #expect(OrphanedAppData.isOwnPrefix("com.acme.notes", "com.acme."))
        #expect(!OrphanedAppData.isOwnPrefix("com.acmetools.viewer", "com.acme."))
        #expect(!OrphanedAppData.isOwnPrefix("com.acme.notes", " . "))
    }
}
