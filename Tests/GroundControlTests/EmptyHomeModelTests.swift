import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// A fresh Mac (`--fixture-empty`): no project folders, no NAS folder chosen, nothing to clean.
@MainActor
@Suite("Model on an empty home")
struct EmptyHomeModelTests {
    final class World {
        let world: FixtureWorld
        init(empty: Bool = true) throws { world = try FixtureWorld.create(scale: 0.01, empty: empty) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            return e
        }
    }

    @Test func emptyHomeHasNoRootsNoProjectsNoDestination() async throws {
        let w = try World()
        let m = GroundControlModel(environment: w.env)
        #expect(m.settings.projectRootsAreAutomatic)
        #expect(m.projectRoots.isEmpty)
        await m.scanProjects()
        #expect(m.projects.isEmpty)
        #expect(m.offloadDestination == nil)
        await m.refreshDestinationNow()
        #expect(m.destinationCheck == .notSet)
        await m.scanAll()
        #expect(m.totalReclaimable == 0)
        await m.scanOffloadCandidates()
        #expect(m.offloadCandidates.isEmpty)
    }

    @Test func addingAndRemovingRootsAndChoosingANASFolder() async throws {
        let w = try World()
        let m = GroundControlModel(environment: w.env)
        let work = w.world.home.appending(path: "Work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        m.addProjectRoot(work)
        #expect(m.settings.projectRoots == ["~/Work"])
        #expect(w.world.settingsStore.load().projectRoots == ["~/Work"])
        m.removeProjectRoot("~/Work")
        #expect(m.settings.projectRoots == [])
        #expect(m.projectRoots.isEmpty)
        m.useDetectedProjectRoots()
        #expect(m.settings.projectRootsAreAutomatic)

        m.setOffloadDestination(w.world.nasFolder)
        #expect(m.offloadDestination?.path == w.world.nasFolder.path)
        await m.refreshDestinationNow()
        #expect(m.destinationCheck.isReady)
        m.setOffloadDestination(nil)
        await m.refreshDestinationNow()
        #expect(m.destinationCheck == .notSet)
    }

    @Test func populatedFixtureDetectsItsProjectFolder() async throws {
        let w = try World(empty: false)
        let m = GroundControlModel(environment: w.env)
        #expect(m.settings.projectRootsAreAutomatic)
        #expect(m.projectRoots == ["~/WebstormProjects"])
        // Adding a folder starts from what was detected.
        let extra = w.world.home.appending(path: "Clients", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        m.addProjectRoot(extra)
        #expect(m.settings.projectRoots == ["~/WebstormProjects", "~/Clients"])
    }

    @Test func ownBundleIDPrefixesAreEditable() throws {
        let w = try World()
        let m = GroundControlModel(environment: w.env)
        m.addOwnBundleIDPrefix("  com.acme. ")
        m.addOwnBundleIDPrefix("nodots")
        #expect(m.settings.ownBundleIDPrefixes == ["uk.co.tom-jordan.", "com.acme."])
        m.removeOwnBundleIDPrefix("uk.co.tom-jordan.")
        #expect(w.world.settingsStore.load().ownBundleIDPrefixes == ["com.acme."])
    }
}
