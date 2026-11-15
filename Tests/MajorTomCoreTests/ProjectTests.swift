import Foundation
import Testing
@testable import MajorTomCore

/// Project discovery and hibernation, only ever against fixture trees in the temp directory.
/// Git is real but isolated from the user's config, and only runs inside the fixture.
@Suite("Projects")
struct ProjectTests {
    static var git: ProcessRunner {
        var r = ProcessRunner()
        r.environmentOverrides = FixtureGit.isolatedEnvironment
        return r
    }

    let longAgo = Date(timeIntervalSinceNow: -86400 * 200)

    func scanner(_ f: Fixture) -> ProjectScanner {
        ProjectScanner(roots: [f.home.appending(path: "WebstormProjects")], git: Self.git)
    }

    func projectsRoot(_ f: Fixture) -> URL { f.home.appending(path: "WebstormProjects") }

    func project(_ projects: [Project], _ rel: String) throws -> Project {
        try #require(projects.first { $0.relativePath == rel }, "no project \(rel) in \(projects.map(\.relativePath))")
    }

    func engine(_ f: Fixture, settings: Settings = Settings()) -> CleanEngine {
        CleanEngine(rules: [], context: f.context(settings: settings), history: f.historyLog,
                    freeSpace: { 0 }, git: Self.git)
    }

    /// Every file and directory under `dir` (not following symlinks) with its contents, minus `excluding` subtrees.
    func snapshot(_ dir: URL, excluding: [URL] = []) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let skip = Set(excluding.map(\.standardizedFileURL.path))
        let e = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        for case let url as URL in e {
            let path = url.standardizedFileURL.path
            if skip.contains(path) { e.skipDescendants(); continue }
            let rel = String(path.dropFirst(dir.standardizedFileURL.path.count))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true || values.isSymbolicLink == true {
                out[rel] = Data("dir".utf8)
            } else {
                out[rel] = try Data(contentsOf: url)
            }
        }
        return out
    }

    // MARK: Discovery

    @Test func monorepoIsOneProjectAndNestedLayoutsAreFound() async throws {
        let f = try Fixture()
        let root = "WebstormProjects"
        // A pnpm monorepo (git) with apps/* and packages/*.
        try f.text("\(root)/web/mono/package.json", "{}")
        try f.text("\(root)/web/mono/.gitignore", "node_modules\n.next\n.turbo\n")
        try f.text("\(root)/web/mono/pnpm-lock.yaml", "")
        try f.text("\(root)/web/mono/apps/web/package.json", "{}")
        try f.file("\(root)/web/mono/apps/web/node_modules/next/index.js")
        try f.file("\(root)/web/mono/apps/web/.next/cache/x")
        try f.text("\(root)/web/mono/packages/ui/package.json", "{}")
        try f.file("\(root)/web/mono/packages/ui/node_modules/x/index.js")
        try f.file("\(root)/web/mono/node_modules/.pnpm/x")
        try f.file("\(root)/web/mono/.turbo/cache/x")
        // A decoy "project" inside node_modules must never be found.
        try f.text("\(root)/web/mono/node_modules/some-pkg/package.json", "{}")
        try f.dir("\(root)/web/mono/node_modules/some-pkg/.git")
        try FixtureGit.commitAll(f.home.appending(path: "\(root)/web/mono"), date: longAgo)
        // Nested container: web/acme-notes/acme-notes.reactnative/ios/Pods.
        try f.text("\(root)/web/acme-notes/acme-notes.reactnative/package.json", "{}")
        try f.text("\(root)/web/acme-notes/acme-notes.reactnative/ios/Podfile", "")
        try f.file("\(root)/web/acme-notes/acme-notes.reactnative/ios/Pods/React/x")
        try f.text("\(root)/web/acme-notes/acme-notes.reactnative/ios/Pods/React/package.json", "{}")
        // Spaces and brackets in names.
        try f.text("\(root)/[02] clients/widgets/Timer App/package.json", "{}")
        try f.file("\(root)/[02] clients/widgets/Timer App/node_modules/x/index.js")

        let projects = await scanner(f).discover()
        #expect(Set(projects.map(\.relativePath)) == [
            "web/mono", "web/acme-notes/acme-notes.reactnative", "[02] clients/widgets/Timer App",
        ])
        let mono = try project(projects, "web/mono")
        #expect(mono.isGitRepo)
        #expect(Set(mono.strippable.map(\.relativePath)) == [
            "node_modules", ".turbo", "apps/web/node_modules", "apps/web/.next", "packages/ui/node_modules",
        ])
        #expect(mono.restoreCommands == ["pnpm install"])
        let rn = try project(projects, "web/acme-notes/acme-notes.reactnative")
        #expect(rn.strippable.map(\.relativePath) == ["ios/Pods"])
        #expect(rn.restoreCommands == ["cd ios && pod install"])
        let timerApp = try project(projects, "[02] clients/widgets/Timer App")
        #expect(timerApp.strippable.map(\.relativePath) == ["node_modules"])
    }

    @Test func nestedRepositoriesAreSeparateProjects() async throws {
        let f = try Fixture()
        // A non-git folder with its own package.json that also holds git repos.
        try f.text("WebstormProjects/launchpad/package.json", "{}")
        try f.file("WebstormProjects/launchpad/node_modules/x/index.js")
        try f.text("WebstormProjects/launchpad/launchpad.nextjs/package.json", "{}")
        try f.text("WebstormProjects/launchpad/launchpad.nextjs/.gitignore", "node_modules\n")
        try f.file("WebstormProjects/launchpad/launchpad.nextjs/node_modules/y/index.js")
        try FixtureGit.commitAll(f.home.appending(path: "WebstormProjects/launchpad/launchpad.nextjs"), date: longAgo)

        let projects = await scanner(f).discover()
        let parent = try project(projects, "launchpad")
        let child = try project(projects, "launchpad/launchpad.nextjs")
        #expect(parent.strippable.map(\.relativePath) == ["node_modules"])
        #expect(child.strippable.map(\.relativePath) == ["node_modules"])
        #expect(!parent.isGitRepo && child.isGitRepo)
    }

    @Test func symlinksAreNotFollowed() async throws {
        let f = try Fixture()
        let outside = try f.dir("elsewhere/real-project")
        try f.text("elsewhere/real-project/package.json", "{}")
        try f.file("elsewhere/real-project/node_modules/x/index.js")
        try f.text("WebstormProjects/app/package.json", "{}")
        try f.dir("WebstormProjects")
        try f.symlink("WebstormProjects/linked", to: outside)
        try f.symlink("WebstormProjects/app/node_modules", to: outside.appending(path: "node_modules"))

        let projects = await scanner(f).discover()
        #expect(projects.map(\.relativePath) == ["app"])
        #expect(try project(projects, "app").strippable.isEmpty)
    }

    // MARK: What counts as strippable

    @Test func buildOutputsNeedGitIgnoreOrAKnownFramework() async throws {
        let f = try Fixture()
        let repo = "WebstormProjects/repo"
        try f.text("\(repo)/package.json", "{}")
        try f.text("\(repo)/.gitignore", "dist/\n")
        try f.file("\(repo)/dist/main.js")                       // ignored -> strip
        try f.file("\(repo)/build/release.sh")                   // tracked -> keep
        try f.text("\(repo)/vendored/package.json", "{}")
        try f.file("\(repo)/vendored/node_modules/x/index.js")   // tracked node_modules -> keep
        try FixtureGit.commitAll(f.home.appending(path: repo), date: longAgo)
        try f.text("\(repo)/tool/package.json", "{}")
        try f.file("\(repo)/tool/build/out.js")                  // untracked, not ignored, no framework -> keep
        try f.text("\(repo)/web/package.json", "{}")
        try f.text("\(repo)/web/vite.config.ts", "export default {}")
        try f.file("\(repo)/web/dist/index.html")                // untracked but Vite output -> strip

        let plain = "WebstormProjects/plain"
        try f.text("\(plain)/package.json", #"{"devDependencies":{"react-scripts":"5.0.1"}}"#)
        try f.file("\(plain)/build/static/main.js")              // CRA output, no git -> strip
        try f.file("\(plain)/dist/thing.js")                     // no git, no framework -> keep
        try f.text("\(plain)/android/build.gradle", "")
        try f.text("\(plain)/android/app/build.gradle", "")
        try f.file("\(plain)/android/app/build/outputs/app.apk") // Gradle module output -> strip
        try f.text("\(plain)/lib/package.json", #"{"devDependencies":{"vite":"6.0.0"}}"#)
        try f.file("\(plain)/lib/dist/.env.production")          // contains .env -> keep
        try f.text("\(plain)/src/target/notes.md", "not a cargo target")  // `target` without Cargo.toml -> not a candidate

        let projects = await scanner(f).discover()
        let r = try project(projects, "repo")
        #expect(Set(r.strippable.map(\.relativePath)) == ["dist", "web/dist"])
        #expect(Set(r.skipped.map(\.relativePath)) == ["build", "vendored/node_modules", "tool/build"])
        #expect(r.skipped.first { $0.relativePath == "build" }?.reason == "contains files tracked by git")
        #expect(r.strippable.first { $0.relativePath == "dist" }?.reason.hasPrefix("ignored by git") == true)

        let p = try project(projects, "plain")
        #expect(Set(p.strippable.map(\.relativePath)) == ["build", "android/app/build"])
        #expect(Set(p.skipped.map(\.relativePath)) == ["dist", "lib/dist"])
    }

    @Test func restoreCommandsComeFromLockfiles() async throws {
        let f = try Fixture()
        let r = "WebstormProjects"
        try f.text("\(r)/p/package.json", "{}"); try f.text("\(r)/p/pnpm-lock.yaml", "")
        try f.dir("\(r)/p/node_modules"); try f.text("\(r)/p/apps/a/package.json", "{}"); try f.dir("\(r)/p/apps/a/node_modules")
        try f.text("\(r)/y/package.json", "{}"); try f.text("\(r)/y/yarn.lock", ""); try f.dir("\(r)/y/node_modules")
        try f.text("\(r)/y/ios/Podfile", ""); try f.dir("\(r)/y/ios/Pods")
        try f.text("\(r)/b/package.json", "{}"); try f.text("\(r)/b/bun.lockb", ""); try f.dir("\(r)/b/node_modules")
        try f.text("\(r)/n/package.json", "{}"); try f.text("\(r)/n/my app/package.json", "{}")
        try f.text("\(r)/n/my app/package-lock.json", "{}"); try f.dir("\(r)/n/my app/node_modules")
        try f.text("\(r)/m/package.json", #"{"packageManager":"yarn@4.5.0"}"#); try f.dir("\(r)/m/node_modules")
        try f.text("\(r)/c/Cargo.toml", ""); try f.text("\(r)/c/Cargo.lock", ""); try f.dir("\(r)/c/target")

        let projects = await scanner(f).discover()
        #expect(try project(projects, "p").restoreCommands == ["pnpm install"])
        #expect(try project(projects, "y").restoreCommands == ["yarn install", "cd ios && pod install"])
        #expect(try project(projects, "b").restoreCommands == ["bun install"])
        #expect(try project(projects, "n").restoreCommands == ["cd 'my app' && npm install"])
        #expect(try project(projects, "m").restoreCommands == ["yarn install"])
        let c = try project(projects, "c")
        #expect(c.restoreCommands.isEmpty)
        #expect(c.strippable.map(\.kind) == [.cargoTarget])
        #expect(c.restoreSummary == "Build outputs regenerate on the next build.")
    }

    // MARK: Activity and git state

    @Test func activityIgnoresDependencyAndBuildDirs() async throws {
        let f = try Fixture()
        let rel = "WebstormProjects/old"
        try f.text("\(rel)/package.json", "{}")
        try f.text("\(rel)/src/index.ts", "x")
        try FixtureGit.commitAll(f.home.appending(path: rel), date: longAgo)
        try FixtureWorld.setModificationDates(in: f.home.appending(path: rel), to: longAgo)
        // Fresh files inside node_modules / .next don't count as activity.
        try f.file("\(rel)/node_modules/x/index.js")
        try f.file("\(rel)/.next/cache/x")

        var projects = await scanner(f).discover()
        var p = try project(projects, "old")
        #expect(p.isStale(afterDays: 90))
        #expect(abs((p.lastCommit ?? .distantPast).timeIntervalSince(longAgo)) < 2)
        #expect(!p.isStale(afterDays: 365))

        try f.text("\(rel)/src/index.ts", "edited today")
        projects = await scanner(f).discover()
        p = try project(projects, "old")
        #expect(!p.isStale(afterDays: 90))
    }

    @Test func gitWarningsReportUncommittedAndUnpushedWork() async throws {
        let f = try Fixture()
        let a = f.home.appending(path: "WebstormProjects/a")
        try f.text("WebstormProjects/a/package.json", "{}")
        try FixtureGit.commitAll(a, date: longAgo)
        let remote = f.root.appending(path: "remote.git")
        try FixtureGit.run(["init", "-q", "--bare", remote.path], in: f.root, date: longAgo)
        try FixtureGit.run(["remote", "add", "origin", remote.path], in: a, date: longAgo)
        try FixtureGit.run(["push", "-q", "origin", "main"], in: a, date: longAgo)
        var projects = await scanner(f).discover()
        #expect(try project(projects, "a").warnings.isEmpty)

        try f.text("WebstormProjects/a/README.md", "new")
        try FixtureGit.commitAll(a, date: Date())
        try f.text("WebstormProjects/a/package.json", #"{"changed":true}"#)
        try f.text("WebstormProjects/a/untracked.txt", "x")
        projects = await scanner(f).discover()
        let git = try #require(try project(projects, "a").git)
        #expect(git.uncommittedChanges == 2)
        #expect(git.unpushedCommits == 1)
        #expect(git.hasRemote)
        #expect(git.branch == "main")

        try f.text("WebstormProjects/b/package.json", "{}")
        try FixtureGit.commitAll(f.home.appending(path: "WebstormProjects/b"), date: longAgo)
        projects = await scanner(f).discover()
        #expect(try project(projects, "b").git?.hasRemote == false)
        #expect(try project(projects, "b").warnings.contains { $0.contains("no git remote") })
    }

    // MARK: Hibernation safety

    /// A realistic git project: hibernating it deletes exactly the strippable dirs and nothing else —
    /// not source, not `.git`, not `.env*`, not tracked files, not a nested repo's dependencies.
    @Test func hibernationTouchesOnlyStrippableDirs() async throws {
        let f = try Fixture()
        let rel = "WebstormProjects/[02] clients/shop"
        let projectURL = f.home.appending(path: rel)
        try f.text("\(rel)/package.json", "{}")
        try f.text("\(rel)/pnpm-lock.yaml", "")
        try f.text("\(rel)/.gitignore", "node_modules\ndist\n.next\n.env\n.env.local\nbuild\n")
        try f.text("\(rel)/.env", "SECRET=1")
        try f.text("\(rel)/.env.local", "SECRET=2")
        try f.text("\(rel)/src/index.ts", "source")
        try f.text("\(rel)/build/keep-me.sh", "tracked build script")
        try FixtureGit.run(["init", "-q", "-b", "main"], in: projectURL, date: longAgo)
        try FixtureGit.run(["add", "-A"], in: projectURL, date: longAgo)
        try FixtureGit.run(["add", "-f", "build/keep-me.sh"], in: projectURL, date: longAgo)
        try FixtureGit.run(["commit", "-q", "-m", "init"], in: projectURL, date: longAgo)
        try f.file("\(rel)/node_modules/react/index.js", bytes: 50_000)
        try f.file("\(rel)/apps/web/node_modules/next/index.js", bytes: 20_000)
        try f.text("\(rel)/apps/web/package.json", "{}")
        try f.file("\(rel)/apps/web/.next/cache/x", bytes: 30_000)
        try f.file("\(rel)/dist/main.js", bytes: 10_000)
        try f.text("\(rel)/packages/cfg/package.json", "{}")
        try f.text("\(rel)/packages/cfg/dist/.env", "SECRET=3")  // .env inside an ignored dist: kept
        // A nested repository with its own node_modules belongs to itself, not to `shop`.
        try f.text("\(rel)/vendor-repo/package.json", "{}")
        try FixtureGit.commitAll(f.home.appending(path: "\(rel)/vendor-repo"), date: longAgo)
        try f.file("\(rel)/vendor-repo/node_modules/x/index.js")

        let projects = await ProjectScanner.sized(await scanner(f).discover())
        let shop = try project(projects, "[02] clients/shop")
        let strip = shop.strippable.map(\.path)
        #expect(Set(shop.strippable.map(\.relativePath)) == ["node_modules", "apps/web/node_modules", "apps/web/.next", "dist"])
        #expect(shop.skipped.contains { $0.relativePath == "packages/cfg/dist" })
        #expect(shop.skipped.contains { $0.relativePath == "build" })
        #expect(shop.strippableSize > 0)

        let before = try snapshot(projectURL, excluding: strip)
        let ruleID = ProjectHibernation.ruleID(for: shop.path)
        let report = await engine(f).clean([CleanRequest(ruleID: ruleID, itemIDs: strip.map(\.path))], execute: true)
        #expect(report.outcomes.allSatisfy { $0.status == .cleaned }, "\(report.outcomes.map(\.status))")
        #expect(report.outcomes.count == 4)
        for url in strip { #expect(!f.exists(url)) }
        // Everything else is byte-for-byte identical, including .git, .env*, tracked build/ and the nested repo.
        let after = try snapshot(projectURL)
        #expect(after == before)
        #expect(after.keys.contains("/.env") && after.keys.contains("/.env.local") && after.keys.contains("/build/keep-me.sh"))
        #expect(after.keys.contains("/vendor-repo/node_modules/x/index.js"))
        #expect(after.keys.contains { $0.hasPrefix("/.git/") })

        // Logged to history, and the hibernation record carries the restore command.
        #expect(f.historyLog.entries().last?.ruleIDs == [ruleID])
        let records = HibernationRecord.records(from: report, projects: projects)
        #expect(records.count == 1)
        #expect(records.first?.restoreCommands == ["pnpm install"])
        #expect(Set(records.first?.removed ?? []) == ["node_modules", "apps/web/node_modules", "apps/web/.next", "dist"])
        let log = HibernationLog(url: f.root.appending(path: "hibernations.jsonl"))
        try log.append(records)
        #expect(log.latestByProject()[shop.path.path]?.removed.count == 4)

        // Afterwards the project has nothing left to strip.
        let again = try #require(await scanner(f).analyze(projectAt: shop.path))
        #expect(again.strippable.isEmpty)
    }

    @Test func hibernationRefusesAnythingTheProjectRuleDidNotProduce() async throws {
        let f = try Fixture()
        let rel = "WebstormProjects/app"
        let app = f.home.appending(path: rel)
        try f.text("\(rel)/package.json", "{}")
        try f.text("\(rel)/.env", "SECRET=1")
        try f.text("\(rel)/src/index.ts", "source")
        try f.text("\(rel)/.gitignore", "node_modules\n")
        try FixtureGit.commitAll(app, date: longAgo)
        try f.file("\(rel)/node_modules/x/index.js")
        let before = try snapshot(app)
        let ruleID = ProjectHibernation.ruleID(for: app)
        let bogus = [app, app.appending(path: ".git"), app.appending(path: ".env"), app.appending(path: "src"),
                     app.appending(path: "src/index.ts"), app.appending(path: "package.json"), f.home,
                     projectsRoot(f)].map(\.path)
        let report = await engine(f).clean([CleanRequest(ruleID: ruleID, itemIDs: bogus)], execute: true)
        #expect(report.outcomes.count == bogus.count)
        #expect(report.outcomes.allSatisfy { if case .skipped = $0.status { true } else { false } })
        #expect(try snapshot(app) == before)

        // Pinned and ignored projects resolve to nothing, so even their node_modules is refused.
        let nm = app.appending(path: "node_modules").path
        var pinned = Settings()
        pinned.pinnedProjects = [app.path]
        var ignored = Settings()
        ignored.ignoredProjects = [app.path]
        for settings in [pinned, ignored] {
            let r = await engine(f, settings: settings).clean([CleanRequest(ruleID: ruleID, itemIDs: [nm])], execute: true)
            #expect(r.outcomes.first?.status != .cleaned)
            #expect(f.exists(URL(filePath: nm)))
        }

        // A project outside the configured roots resolves to nothing either.
        let stray = try f.dir("elsewhere/stray")
        try f.text("elsewhere/stray/package.json", "{}")
        try f.file("elsewhere/stray/node_modules/x/index.js")
        let strayNM = stray.appending(path: "node_modules")
        let r = await engine(f).clean([CleanRequest(ruleID: ProjectHibernation.ruleID(for: stray), itemIDs: [strayNM.path])],
                                      execute: true)
        #expect(r.outcomes.first?.status != .cleaned)
        #expect(f.exists(strayNM))

        // Dry run (the default) never deletes.
        let dry = await engine(f).clean([CleanRequest(ruleID: ruleID, itemIDs: [nm])])
        #expect(dry.dryRun && dry.outcomes.first?.status == .wouldClean)
        #expect(f.exists(URL(filePath: nm)))
    }

    @Test func settingsDecodeProjectFieldsTolerantly() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"staleAfterDays": 30}"#.utf8))
        #expect(old.staleAfterDays == 30 && old.pinnedProjects.isEmpty && old.ignoredProjects.isEmpty)
        var s = Settings()
        s.pinnedProjects = ["/a"]
        s.ignoredProjects = ["/b"]
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }
}
