import CoreServices
import Foundation
import Synchronization

/// Where installed apps are looked up.
public struct AppInventorySource: Sendable {
    /// Folders searched for `.app` bundles (and the apps, extensions and helpers nested inside them).
    public var directories: [URL]
    /// Also ask Spotlight for every application bundle on the Mac.
    public var spotlight: Bool
    /// Also ask LaunchServices about each candidate bundle ID before calling it orphaned.
    public var launchServices: Bool
    /// Look at `~/Library/Containers` only when this says so. Reading another app's container without Full
    /// Disk Access makes macOS ask the user, so the live default needs Full Disk Access.
    public var containersReadable: @Sendable () -> Bool

    public init(directories: [URL], spotlight: Bool, launchServices: Bool,
                containersReadable: @escaping @Sendable () -> Bool) {
        self.directories = directories
        self.spotlight = spotlight
        self.launchServices = launchServices
        self.containersReadable = containersReadable
    }

    /// The real Mac: /Applications, ~/Applications, /System/Applications, Spotlight and LaunchServices.
    public static func system(home: URL) -> AppInventorySource {
        AppInventorySource(
            directories: [URL(filePath: "/Applications"), home.appending(path: "Applications"),
                          URL(filePath: "/System/Applications"), URL(filePath: "/System/Library/CoreServices")],
            spotlight: true, launchServices: true,
            containersReadable: { FullDiskAccess.status(home: home) == .granted })
    }

    /// Only the given folders (fixtures and tests): no Spotlight, no LaunchServices.
    public static func only(_ directories: [URL]) -> AppInventorySource {
        AppInventorySource(directories: directories, spotlight: false, launchServices: false, containersReadable: { true })
    }

    var cacheKey: String { directories.map(\.path).joined(separator: ":") + "|\(spotlight)|\(launchServices)" }
}

/// Bundle identifiers of everything installed (lower-cased), including nested apps, extensions and helpers.
public struct InstalledApps: Sendable {
    public var bundleIDs: Set<String>

    /// True if `id` is installed, or is an extension/helper of something installed (or vice versa).
    public func covers(_ id: String) -> Bool {
        let id = id.lowercased()
        if bundleIDs.contains(id) { return true }
        // "com.foo.app.ShipIt" belongs to "com.foo.app"; "com.foo.app" may be the parent of an installed helper.
        var parts = id.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if bundleIDs.contains(parts.joined(separator: ".")) { return true }
        }
        return bundleIDs.contains { $0.hasPrefix(id + ".") }
    }

    /// Another installed app from the same vendor (`com.foo.*`). Data then may be shared — not sure enough.
    public func sameVendor(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let vendor = parts.prefix(2).joined(separator: ".")
        guard !OrphanedAppData.sharedVendorPrefixes.contains(vendor) else { return nil }
        return bundleIDs.first { $0.hasPrefix(vendor + ".") }
    }
}

enum AppInventory {
    private static let cache = Mutex<[String: (Date, InstalledApps)]>([:])
    private static let inFlight = InFlight<InstalledApps>()

    /// Installed apps, cached for a minute (app installs don't change what's on disk under a scan).
    static func load(_ source: AppInventorySource, runner: any CommandRunner) async -> InstalledApps {
        let key = source.cacheKey
        if let (at, apps) = cache.withLock({ $0[key] }), Date().timeIntervalSince(at) < 60 { return apps }
        let apps = await inFlight.value(key: key) {
            var ids = await offPool { scanDirectories(source.directories) }
            if source.spotlight { ids.formUnion(await spotlightBundleIDs(runner)) }
            return InstalledApps(bundleIDs: ids)
        }
        cache.withLock { $0[key] = (Date(), apps) }
        return apps
    }

    static func scanDirectories(_ dirs: [URL]) -> Set<String> {
        var ids: Set<String> = []
        for dir in dirs { collectApps(in: dir.path, depth: 0, into: &ids) }
        return ids
    }

    /// Apps directly in a folder or in plain subfolders (e.g. /Applications/Utilities), two levels deep.
    private static func collectApps(in dir: String, depth: Int, into ids: inout Set<String>) {
        for name in DiskSizer.listDirectory(dir) where !name.hasPrefix(".") {
            let path = dir + "/" + name
            if name.lowercased().hasSuffix(".app") {
                collectBundle(path, into: &ids)
            } else if depth < 2, FS.isDirectory(URL(filePath: path)) {
                collectApps(in: path, depth: depth + 1, into: &ids)
            }
        }
    }

    static let nestedBundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension", "bundle", "plugin", "framework", "loginitem"]
    private static let skippedInsideBundles: Set<String> = ["Resources", "_CodeSignature", "Developer", "Headers", "Modules", "SharedSupport", "Documentation"]

    /// The bundle's own ID plus nested apps, extensions, XPC services, login items and helper frameworks.
    private static func collectBundle(_ path: String, into ids: inout Set<String>) {
        for plist in [path + "/Contents/Info.plist", path + "/WrappedBundle/Info.plist", path + "/Info.plist"] {
            if let id = FS.readPlist(URL(filePath: plist))?["CFBundleIdentifier"] as? String {
                ids.insert(id.lowercased())
                break
            }
        }
        // iOS apps on Apple silicon: /Applications/X.app/Wrapper/X.app
        for name in DiskSizer.listDirectory(path + "/Wrapper") where name.hasSuffix(".app") {
            if let id = FS.readPlist(URL(filePath: path + "/Wrapper/" + name + "/Info.plist"))?["CFBundleIdentifier"] as? String {
                ids.insert(id.lowercased())
            }
        }
        var budget = 3000
        var stack = [(path + "/Contents", 0)]
        while let (dir, depth) = stack.popLast(), budget > 0 {
            for name in DiskSizer.listDirectory(dir) {
                budget -= 1
                if skippedInsideBundles.contains(name) || name.hasSuffix(".lproj") { continue }
                let child = dir + "/" + name
                guard FS.isDirectory(URL(filePath: child)) else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if nestedBundleExtensions.contains(ext) {
                    for plist in [child + "/Contents/Info.plist", child + "/Resources/Info.plist", child + "/Info.plist"] {
                        if let id = FS.readPlist(URL(filePath: plist))?["CFBundleIdentifier"] as? String {
                            ids.insert(id.lowercased())
                            break
                        }
                    }
                }
                if depth < 6 { stack.append((child, depth + 1)) }
            }
        }
    }

    /// Every application bundle Spotlight knows about (any volume, any folder).
    static func spotlightBundleIDs(_ runner: any CommandRunner) async -> Set<String> {
        let query = "kMDItemContentType == 'com.apple.application-bundle'"
        guard let r = await runner.run(["mdfind", "-attr", "kMDItemCFBundleIdentifier", query], timeout: 20),
              r.succeeded else { return [] }
        var ids: Set<String> = []
        for line in r.stdoutString.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "kMDItemCFBundleIdentifier = ", options: .backwards) else { continue }
            let id = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id != "(null)" { ids.insert(id.lowercased()) }
        }
        return ids
    }

    /// LaunchServices knows an app with this bundle ID (anywhere, including other volumes and the Trash).
    static func launchServicesKnows(_ id: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return false }
        return !urls.isEmpty
    }
}

/// Data left behind by apps that are no longer installed: bundle-ID-named folders in Application Support,
/// Caches and Containers (plus the app's HTTPStorages / WebKit / Saved Application State), one item per app.
/// Conservative on purpose: anything uncertain is left out.
public enum OrphanedAppData {
    /// Folders a candidate starts from.
    static let primaryLocations = ["Library/Application Support", "Library/Caches", "Library/Containers"]
    /// Folders only added to an app that is already a candidate.
    static let companionLocations = ["Library/HTTPStorages", "Library/WebKit", "Library/Saved Application State"]
    static var allLocations: [String] { primaryLocations + companionLocations }

    /// Days a folder must have been left alone.
    static let quietDays = 30

    /// Vendors whose prefix is shared by unrelated apps (`com.electron.*`), so "same vendor" means nothing.
    static let sharedVendorPrefixes: Set<String> = ["com.electron", "com.github", "io.github", "com.example", "org.example"]

    /// Command-line tools, developer tooling and SDKs that keep bundle-ID-style folders without being an app
    /// (or are already covered by a more specific rule). Never called orphaned.
    static let toolingPrefixes: [String] = [
        "org.swift.", "com.github.", "io.github.", "org.nodejs.", "org.python.", "org.rust-lang.", "io.flutter.",
        "dev.flutter.", "com.google.android.", "com.android.", "org.gradle.", "com.jetbrains.", "com.microsoft.dotnet",
        "com.vercel.", "dev.expo.", "com.expo.", "host.exp.", "org.cocoapods.", "sh.brew.", "org.homebrew.",
        "com.anthropic.", "com.openai.", "org.llvm.", "com.facebook.", "org.reactjs.", "com.docker.", "io.podman.",
        "org.mozilla.rust", "com.hashicorp.", "io.tuist.", "com.crashlytics", "com.plausiblelabs.", "io.sentry",
        "com.bugsnag.", "org.sparkle-project.", "com.google.firebase", "com.segment.", "com.mixpanel.",
        "com.amplitude.", "com.microsoft.appcenter", "net.hockeyapp.", "io.branch.", "com.squareup.",
        "com.google.keystone", "com.google.gtm",
    ]

    public static let rule = Rule(
        id: "orphaned-app-data",
        title: "Leftovers from removed apps",
        category: .files,
        tier: .review,
        impact: "Settings, caches and saved data of apps that are no longer installed. If you reinstall one of them it starts from scratch (signed out, default settings, local data gone). Each folder goes to the Trash, so you can put it back.",
        recovery: "Put Back from the Trash before emptying it; otherwise the app starts fresh when reinstalled.",
        regenCost: "Only matters if you reinstall the app.",
        method: .trash,
        baseDirectories: { ctx in allLocations.map { ctx.path($0) } },
        resolve: { ctx in try await resolve(ctx) },
        trashOnly: true
    )

    static func resolve(_ ctx: RuleContext) async throws -> [Item] {
        let found = await find(ctx)
        if found.containersSkipped {
            throw PartialResolution(
                items: found.items,
                message: "Containers of removed sandboxed apps (~/Library/Containers) are only checked with Full Disk Access — without it macOS would ask about every app's data.",
                deniedPaths: ["~/Library/Containers"])
        }
        return found.items
    }

    struct Found: Sendable {
        var items: [Item]
        /// Cache folders claimed by an orphan item (the generic App caches rule leaves them out).
        var claimedCachePaths: Set<String>
        var containersSkipped: Bool
    }

    private static let inFlight = InFlight<Found>()

    static func find(_ ctx: RuleContext) async -> Found {
        await inFlight.value(key: ctx.home.path + "|" + ctx.appSources.cacheKey) {
            let apps = await AppInventory.load(ctx.appSources, runner: ctx.runner)
            let containers = ctx.appSources.containersReadable()
            let candidates = await offPool { collectCandidates(ctx, apps: apps, containers: containers) }
            var items: [Item] = []
            var claimed: Set<String> = []
            for c in candidates {
                if ctx.appSources.launchServices, AppInventory.launchServicesKnows(c.bundleID) { continue }
                items.append(c.item(launchServicesChecked: ctx.appSources.launchServices,
                                    spotlightChecked: ctx.appSources.spotlight))
                for p in c.paths where p.path.hasPrefix(ctx.path("Library/Caches").path + "/") { claimed.insert(p.path) }
            }
            return Found(items: items, claimedCachePaths: claimed, containersSkipped: !containers)
        }
    }

    struct Candidate: Sendable {
        var bundleID: String
        var displayName: String
        var paths: [URL]
        var locations: [String]
        var newest: Date

        func item(launchServicesChecked: Bool, spotlightChecked: Bool) -> Item {
            var looked = ["/Applications", "~/Applications", "/System/Applications"]
            if spotlightChecked { looked.append("Spotlight") }
            let where_ = looked.dropLast().joined(separator: ", ") + " or " + looked[looked.count - 1]
            let ls = launchServicesChecked ? "; LaunchServices doesn't know it either" : ""
            let since = newest.formatted(.dateTime.month(.abbreviated).year())
            let note = "Not installed: no app with ID \(bundleID) in \(where_)\(ls). Untouched since \(since). Has: \(locations.joined(separator: ", "))."
            return Item(id: "orphan:" + bundleID.lowercased(), displayName: displayName, path: paths[0],
                        companionPaths: Array(paths.dropFirst()), lastUsed: newest, note: note, methodOverride: .trash)
        }
    }

    /// Bundle-ID-shaped folder names that pass every check, grouped per app.
    static func collectCandidates(_ ctx: RuleContext, apps: InstalledApps, containers: Bool) -> [Candidate] {
        let ownProjects = projectNameTokens(ctx)
        let ownPrefixes = ctx.settings.ownBundleIDPrefixes
        var byID: [String: Candidate] = [:]
        var rejected: Set<String> = []
        let cutoff = Date(timeIntervalSinceNow: -Double(quietDays) * 86400)

        for location in primaryLocations {
            if location == "Library/Containers", !containers { continue }
            let base = ctx.path(location)
            for url in FS.children(of: base, directoriesOnly: true) {
                var id = url.lastPathComponent
                if location == "Library/Containers",
                   let meta = FS.readPlist(url.appending(path: ".com.apple.containermanagerd.metadata.plist")),
                   let real = meta["MCMMetadataIdentifier"] as? String {
                    id = real
                }
                let key = id.lowercased()
                if rejected.contains(key) { continue }
                guard isCandidateName(id, apps: apps, ownProjects: ownProjects, ownPrefixes: ownPrefixes) else { rejected.insert(key); continue }
                var c = byID[key] ?? Candidate(bundleID: id, displayName: friendlyName(id), paths: [], locations: [],
                                               newest: .distantPast)
                c.paths.append(url)
                c.locations.append(locationName(location))
                byID[key] = c
            }
        }
        var out: [Candidate] = []
        for (key, var c) in byID {
            for location in companionLocations {
                let name = location.hasSuffix("Saved Application State") ? c.bundleID + ".savedState" : c.bundleID
                let url = ctx.path(location).appending(path: name)
                if FS.isDirectory(url) {
                    c.paths.append(url)
                    c.locations.append(locationName(location))
                }
            }
            // Recently touched: the app (or a tool) is still using it.
            var newest = c.paths.compactMap { recentActivity($0) }.max() ?? .distantPast
            let prefs = ctx.path("Library/Preferences/\(c.bundleID).plist")
            if let d = (try? FileManager.default.attributesOfItem(atPath: prefs.path))?[.modificationDate] as? Date {
                newest = max(newest, d)
            }
            guard newest != .distantPast, newest < cutoff else { continue }
            c.newest = newest
            _ = key
            out.append(c)
        }
        return out.sorted { $0.bundleID.lowercased() < $1.bundleID.lowercased() }
    }

    /// Looks like a reverse-DNS bundle ID, isn't Apple's, isn't tooling, isn't installed, isn't one of the
    /// user's own projects or bundle-ID prefixes (Settings), and no app from the same vendor is installed.
    static func isCandidateName(_ id: String, apps: InstalledApps, ownProjects: Set<String>,
                                ownPrefixes: [String] = []) -> Bool {
        let lower = id.lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard lower.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }), lower.allSatisfy(\.isASCII) else { return false }
        guard let tld = parts.first, (2...6).contains(tld.count), tld.allSatisfy(\.isLetter) else { return false }
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.") || lower.hasSuffix(".savedstate") { return false }
        if toolingPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        if ownPrefixes.contains(where: { isOwnPrefix(lower, $0) }) { return false }
        if parts.contains("cli") || parts.contains("daemon") || parts.contains("agent") { return false }
        if SystemRules.coveredCacheNames.contains(id) || SystemRules.knownCacheNotes[id] != nil { return false }
        if apps.covers(lower) || apps.sameVendor(lower) != nil { return false }
        if parts.dropFirst().contains(where: { ownProjects.contains(normalise(String($0))) }) { return false }
        return true
    }

    /// `com.me.` and `com.me` both match `com.me.app` (and `com.me` itself) but not `com.metal.app`.
    static func isOwnPrefix(_ lowerID: String, _ prefix: String) -> Bool {
        var p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        while p.hasSuffix(".") { p.removeLast() }
        guard !p.isEmpty else { return false }
        return lowerID == p || lowerID.hasPrefix(p + ".")
    }

    /// Names of folders under the project roots (three levels), normalised — so data of an app the user builds
    /// themselves (`com.acme.notes` next to `~/Projects/notes`) is never called orphaned.
    static func projectNameTokens(_ ctx: RuleContext) -> Set<String> {
        var out: Set<String> = []
        func visit(_ dir: URL, _ depth: Int) {
            for child in FS.children(of: dir, directoriesOnly: true) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || Walk.neverDescend.contains(name) { continue }
                for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where token.count >= 4 {
                    out.insert(normalise(String(token)))
                }
                let whole = normalise(name)
                if whole.count >= 4 { out.insert(whole) }
                if depth < 3 { visit(child, depth + 1) }
            }
        }
        for root in ctx.settings.expandedProjectRoots(home: ctx.home) { visit(root, 1) }
        return out
    }

    static func normalise(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func friendlyName(_ id: String) -> String {
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return "\(last) (\(id))"
    }

    static func locationName(_ location: String) -> String {
        switch location {
        case "Library/Application Support": "Application Support"
        case "Library/Caches": "Caches"
        case "Library/Containers": "Container"
        case "Library/HTTPStorages": "HTTP storage"
        case "Library/WebKit": "WebKit data"
        default: "Saved window state"
        }
    }

    /// Newest modification date over a folder's first three levels (bounded), or nil if unreadable.
    static func recentActivity(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        var newest = UserFilesWalker.date(st.st_mtimespec)
        var budget = 4000
        var stack = [(url.path, 0)]
        while let (dir, depth) = stack.popLast(), budget > 0 {
            for name in DiskSizer.listDirectory(dir) {
                budget -= 1
                let child = dir + "/" + name
                var cst = stat()
                guard lstat(child, &cst) == 0 else { continue }
                newest = max(newest, UserFilesWalker.date(cst.st_mtimespec))
                if (cst.st_mode & S_IFMT) == S_IFDIR, depth < 2 { stack.append((child, depth + 1)) }
            }
        }
        return newest
    }
}
