import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// Projects section of the model, against the fixture world's fake projects (temp directory only).
@MainActor
@Suite("Projects model")
struct ProjectsModelTests {
    final class World {
        let world: FixtureWorld
        init() throws { world = try FixtureWorld.create(scale: 0.01) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            return e
        }
        func url(_ rel: String) -> URL { world.projectsRoot.appending(path: rel) }
        func exists(_ rel: String) -> Bool { FS.exists(url(rel)) }
    }

    func scanned(_ w: World) async -> GroundControlModel {
        let m = GroundControlModel(environment: w.env)
        await m.scanProjects()
        return m
    }

    func project(_ m: GroundControlModel, _ rel: String) throws -> Project {
        try #require(m.projects.first { $0.relativePath == rel })
    }

    @Test func fixtureProjectsAreDiscoveredWithStatusAndWarnings() async throws {
        let w = try World()
        let m = await scanned(w)
        #expect(m.projectsSized)
        #expect(Set(m.projects.map(\.relativePath)) == Set(FixtureWorld.projectPaths))

        let stellar = try project(m, "web/stellar")
        #expect(m.status(of: stellar) == .stale)
        #expect(Set(stellar.strippable.map(\.relativePath)) == [
            "node_modules", ".turbo", "apps/web/.next", "apps/web/node_modules", "packages/ui/dist", "packages/ui/node_modules",
        ])
        #expect(stellar.restoreCommands == ["pnpm install"])
        #expect(stellar.git?.unpushedCommits == 1)
        #expect(stellar.strippable.allSatisfy { ($0.size ?? 0) > 0 })

        let rn = try project(m, "web/acme-notes/acme-notes.reactnative")
        #expect(m.status(of: rn) == .stale)
        #expect(Set(rn.strippable.map(\.relativePath)) == [
            "node_modules", ".expo", "ios/Pods", "ios/build", "android/build", "android/app/build", "android/.gradle",
        ])
        #expect(rn.restoreCommands == ["yarn install", "cd ios && pod install"])
        #expect(rn.git?.uncommittedChanges == 2)
        #expect(rn.warnings.contains { $0.contains("no git remote") })

        let site = try project(m, "[02] clients/acme-web")
        #expect(m.status(of: site) == .active)
        #expect(site.strippable.map(\.relativePath) == ["node_modules"])
        #expect(Set(site.skipped.map(\.relativePath)) == ["build", "dist"])

        let rusty = try project(m, "[03] tools/rusty")
        #expect(!rusty.isGitRepo && m.status(of: rusty) == .stale)
        #expect(rusty.strippable.map(\.relativePath) == ["target"])

        #expect(m.staleProjects.count == 3)
        #expect(m.staleStrippable > 0 && m.staleStrippable < m.allStrippable)
    }

    @Test func hibernatingStaleProjectsGoesThroughReviewAndHistory() async throws {
        let w = try World()
        let m = await scanned(w)
        m.selectStaleProjects()
        #expect(m.checkedProjects.count == 3)
        let plan = m.hibernationPlan()
        #expect(plan.hibernatesProjects && plan.groups.count == 3)
        #expect(plan.groups.allSatisfy { $0.tier == .costsTime })
        let rnGroup = try #require(plan.groups.first { $0.title.contains("acme-notes") })
        #expect(!rnGroup.warnings.isEmpty)
        #expect(rnGroup.recovery.contains("`yarn install`, then `cd ios && pod install`"))

        await m.reviewHibernation()
        let session = try #require(m.cleanSession)
        #expect(session.canConfirm)
        guard case .reviewing(let dry?) = session.phase else { Issue.record("no dry run"); return }
        #expect(dry.dryRun && dry.outcomes.allSatisfy { $0.status == .wouldClean })
        #expect(w.exists("web/stellar/node_modules"))  // review never deletes

        await m.confirmClean()
        guard case .finished(let report)? = m.cleanSession?.phase else { Issue.record("not finished"); return }
        #expect(!report.dryRun)
        #expect(report.outcomes.allSatisfy { $0.status == .cleaned })
        #expect(report.outcomes.count == plan.itemCount)

        // Strippable dirs are gone; source, git, .env and the active project are untouched.
        for gone in ["web/stellar/node_modules", "web/stellar/apps/web/.next", "web/stellar/packages/ui/dist",
                     "web/acme-notes/acme-notes.reactnative/ios/Pods", "web/acme-notes/acme-notes.reactnative/android/app/build",
                     "[03] tools/rusty/target"] {
            #expect(!w.exists(gone), "\(gone) still exists")
        }
        for kept in ["web/stellar/.env.local", "web/stellar/.git", "web/stellar/apps/web/app/page.tsx",
                     "web/stellar/pnpm-lock.yaml", "web/acme-notes/acme-notes.reactnative/App.tsx",
                     "web/acme-notes/acme-notes.reactnative/notes.md", "web/acme-notes/acme-notes.reactnative/ios/Podfile.lock",
                     "[03] tools/rusty/src/main.rs", "[02] clients/acme-web/node_modules",
                     "[02] clients/acme-web/build/deploy.sh"] {
            #expect(w.exists(kept), "\(kept) was removed")
        }

        // Same history log as every other clean, plus hibernation records with the restore commands.
        #expect(m.history.first?.ruleIDs.allSatisfy(ProjectHibernation.isHibernationRule) == true)
        let stellarPath = w.url("web/stellar").standardizedFileURL.path
        #expect(m.hibernations[stellarPath]?.restoreCommands == ["pnpm install"])
        #expect(m.checkedProjects.isEmpty)
        let stellar = try project(m, "web/stellar")
        #expect(stellar.strippable.isEmpty)
        #expect(m.status(of: stellar) == .hibernated)
        #expect(m.staleProjects.isEmpty)
    }

    @Test func pinnedAndIgnoredProjectsAreNeverOffered() async throws {
        let w = try World()
        let m = await scanned(w)
        let stellar = try project(m, "web/stellar")
        m.setPinned(true, stellar)
        #expect(m.status(of: stellar) == .pinned)
        m.setProjectChecked(true, stellar)
        #expect(m.checkedProjects.isEmpty)
        #expect(m.hibernationPlan(paths: [stellar.path.path]).isEmpty)
        m.selectStaleProjects()
        #expect(!m.checkedProjects.contains(stellar.path.path))
        #expect(w.world.settingsStore.load().pinnedProjects == [stellar.path.path])

        let rusty = try project(m, "[03] tools/rusty")
        m.ignoreProject(rusty)
        #expect(!m.visibleProjects.contains { $0.id == rusty.id })
        #expect(!m.checkedProjects.contains(rusty.path.path))
        m.unignoreProject(path: rusty.path.path)
        #expect(m.visibleProjects.contains { $0.id == rusty.id })

        // Stale threshold is a setting.
        m.setStaleAfterDays(400)
        #expect(m.staleProjects.isEmpty)
        #expect(w.world.settingsStore.load().staleAfterDays == 400)
    }

    @Test func hibernateDemoIsFixtureOnly() async throws {
        let w = try World()
        var live = w.env
        live.fixture = nil
        let m = GroundControlModel(environment: live)
        await m.runDemo("hibernate")
        #expect(m.cleanSession == nil)
        #expect(w.exists("web/stellar/node_modules"))
    }
}
