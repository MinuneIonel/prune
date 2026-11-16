import Foundation
import MajorTomCore

// Minimal argument handling (no third-party dependency needed for four subcommands).

let usage = """
majortom — Ground Control's command line

USAGE
  majortom scan [--rule <id>]... [--items] [--json] [--large-mb N] [--old-days N] [--old-min-mb N]
  majortom rules [--json]
  majortom clean --rule <id> [--item <id>]... [--flagged] [--action <id>] [--execute] [--json]
  majortom history [--json]
  majortom projects [--stale] [--dirs] [--json]
  majortom offload [--candidates] [--json]
  majortom map [--path <folder>]
  majortom compare --from <folder> --to <backup folder>

clean is a DRY RUN unless --execute is given. Without --item, every cleanable
item of the rule is selected (protected and report-only items are never touched).

projects lists projects under the configured roots with their strippable
directories (sizes, restore commands, git warnings). It never changes anything;
hibernating is done from the app's review sheet.

offload shows whether the NAS destination is a mounted network share, and what
has been offloaded (with each archive's restore command). --candidates also lists
what could be offloaded (stale projects, Xcode Archives, large cold files) with
sizes. It never copies, moves or deletes anything; offloading and restoring are
done from the app.

map walks a folder (default: home) and prints what takes the space, by kind and
by where it came from. compare shows which top-level items of a folder are on its
backup. Both only read.

--large-mb / --old-days / --old-min-mb override the Files thresholds from Settings
for this run only (they are not saved).
"""

struct Args {
    var command: String
    var flags: Set<String> = []
    var values: [String: [String]] = [:]

    init(_ argv: [String]) throws {
        var rest = argv.dropFirst()
        guard let cmd = rest.first else { throw CLIError(usage) }
        command = cmd
        rest = rest.dropFirst()
        let valued: Set<String> = ["--rule", "--item", "--action", "--large-mb", "--old-days", "--old-min-mb", "--path",
                                   "--from", "--to"]
        while let a = rest.first {
            rest = rest.dropFirst()
            if valued.contains(a) {
                guard let v = rest.first else { throw CLIError("\(a) needs a value") }
                rest = rest.dropFirst()
                values[a, default: []].append(v)
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                throw CLIError("unexpected argument: \(a)\n\n\(usage)")
            }
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
}

struct CLIError: Error { var message: String; init(_ m: String) { message = m } }

func fmt(_ b: Int64?) -> String { b.map(ByteFormat.string) ?? "—" }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}

func wrap(_ text: String, width: Int, indent: String) -> String {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
        if line.count + word.count + 1 > width, !line.isEmpty { lines.append(line); line = "" }
        line += (line.isEmpty ? "" : " ") + word
    }
    if !line.isEmpty { lines.append(line) }
    return lines.map { indent + $0 }.joined(separator: "\n")
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func printJSON<T: Encodable>(_ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try enc.encode(value))
    print()
}

struct RuleInfo: Encodable {
    var id, title, category, tier, impact, recovery, regenCost, method: String
    init(_ r: Rule) {
        id = r.id; title = r.title; category = r.category.rawValue; tier = r.tier.rawValue
        impact = r.impact; recovery = r.recovery; regenCost = r.regenCost; method = r.method.summary
    }
}

struct ScanJSON: Encodable {
    struct Entry: Encodable {
        var rule: RuleInfo
        var reclaimableBytes: Int64
        var totalBytes: Int64
        var durationSeconds: Double
        var error: String?
        var items: [Item]
        var actions: [RuleAction]
    }
    var scannedAt: Date
    var durationSeconds: Double
    var volumeFreeBytes: Int64?
    var reclaimableBytes: Int64
    var reclaimableByTier: [String: Int64]
    var rules: [Entry]
}

func makeContext(_ args: Args? = nil) throws -> RuleContext {
    var settings = SettingsStore().load()
    func int(_ flag: String) throws -> Int? {
        guard let v = args?.values[flag]?.last else { return nil }
        guard let n = Int(v), n >= 0 else { throw CLIError("\(flag) needs a whole number") }
        return n
    }
    if let n = try int("--large-mb") { settings.largeFileThresholdMB = n }
    if let n = try int("--old-days") { settings.oldFileDays = n }
    if let n = try int("--old-min-mb") { settings.oldFileMinimumMB = n }
    return RuleContext(settings: settings)
}

func scanCommand(_ args: Args) async throws {
    let context = try makeContext(args)
    let all = RuleCatalogue.all.filter { !context.settings.disabledRuleIDs.contains($0.id) }
    let wanted = args.values["--rule"] ?? []
    for id in wanted where !all.contains(where: { $0.id == id }) { throw CLIError("unknown rule: \(id)") }
    let rules = wanted.isEmpty ? all : all.filter { wanted.contains($0.id) }
    let scanner = Scanner(rules: rules, context: context)
    let json = args.has("--json")
    if !json { FileHandle.standardError.write(Data("Scanning \(rules.count) rules…\n".utf8)) }
    let start = Date()
    let results = await scanner.scanAll()
    let elapsed = Date().timeIntervalSince(start)
    let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })

    var byTier: [Tier: Int64] = [:]
    for r in results { if let rule = byID[r.ruleID] { byTier[rule.tier, default: 0] += r.reclaimableSize } }
    let total = results.reduce(Int64(0)) { $0 + $1.reclaimableSize }
    let free = VolumeInfo.availableBytes(at: context.home)

    if json {
        try printJSON(ScanJSON(
            scannedAt: start, durationSeconds: elapsed, volumeFreeBytes: free, reclaimableBytes: total,
            reclaimableByTier: Dictionary(uniqueKeysWithValues: byTier.map { ($0.key.rawValue, $0.value) }),
            rules: results.compactMap { r in
                byID[r.ruleID].map {
                    .init(rule: RuleInfo($0), reclaimableBytes: r.reclaimableSize, totalBytes: r.totalSize,
                          durationSeconds: r.duration, error: r.error, items: r.items, actions: r.actions)
                }
            }))
        return
    }

    let showItems = args.has("--items") || !wanted.isEmpty
    for category in RuleCategory.allCases {
        let inCat = results.filter { byID[$0.ruleID]?.category == category }
        guard !inCat.isEmpty else { continue }
        print("\n== \(category.title) ==")
        for r in inCat.sorted(by: { $0.totalSize > $1.totalSize }) {
            guard let rule = byID[r.ruleID] else { continue }
            let shown = r.reclaimableSize == r.totalSize ? fmt(r.totalSize) : "\(fmt(r.reclaimableSize)) of \(fmt(r.totalSize))"
            let found = r.items.isEmpty ? "  (nothing found)" : "  \(r.items.count) item\(r.items.count == 1 ? "" : "s")"
            print("\(pad(rule.title, 30)) \(pad("[\(rule.tier.label)]", 13)) \(lpad(shown, 20))\(found)   \(String(format: "%.1fs", r.duration))  (\(rule.id))")
            if let e = r.error { print("    ! \(e)") }
            guard !r.items.isEmpty else { continue }
            print(wrap("Impact: " + rule.impact, width: 100, indent: "    "))
            print(wrap("Recovery: \(rule.recovery)  Cost: \(rule.regenCost)", width: 100, indent: "    "))
            if showItems {
                for item in r.items {
                    var marks = ""
                    if item.isProtected { marks += " [protected]" }
                    if item.isFlagged { marks += " [!]" }
                    if item.methodOverride == .reportOnly { marks += " [report only]" }
                    let used = item.lastUsed.map { "used " + dateFormatter.string(from: $0) } ?? ""
                    print("      \(lpad(fmt(item.size), 9))  \(pad(item.displayName, 52)) \(pad(used, 16))\(marks)")
                    if let note = item.note { print("                 \(note)") }
                }
            }
            for action in r.actions {
                print("    → \(action.title): `\(action.commandLine)`\(action.runnable ? "" : " (run it yourself)")")
            }
        }
    }
    print("\nReclaimable: \(fmt(total))  —  " + Tier.allCases.map { "\($0.label) \(fmt(byTier[$0] ?? 0))" }.joined(separator: ", "))
    if let free { print("Free space now: \(fmt(free))") }
    print(String(format: "Scan took %.1f s", elapsed))
}

func rulesCommand(_ args: Args) throws {
    let rules = RuleCatalogue.all
    if args.has("--json") { try printJSON(rules.map(RuleInfo.init)); return }
    for r in rules {
        print("\(pad(r.id, 24)) \(pad(r.tier.label, 11)) \(pad(r.category.rawValue, 16)) \(r.title)")
        print(wrap(r.impact, width: 96, indent: "    "))
    }
}

func cleanCommand(_ args: Args) async throws {
    guard let ruleIDs = args.values["--rule"], ruleIDs.count == 1, let ruleID = ruleIDs.first else {
        throw CLIError("clean needs exactly one --rule <id>\n\n\(usage)")
    }
    let context = try makeContext(args)
    guard let rule = RuleCatalogue.all.first(where: { $0.id == ruleID }) else { throw CLIError("unknown rule: \(ruleID)") }
    let execute = args.has("--execute")
    let engine = CleanEngine(context: context)
    let json = args.has("--json")

    let report: CleanReport
    if let actionID = args.values["--action"]?.first {
        report = await engine.runAction(ruleID: ruleID, actionID: actionID, execute: execute)
    } else {
        // Scan the rule first so the report carries size estimates.
        let scanner = Scanner(rules: [rule], context: context)
        guard let result = await scanner.rescan(ruleID: ruleID) else { throw CLIError("scan failed") }
        var items = result.items.filter(\.isCleanable)
        if args.has("--flagged") { items = items.filter(\.isFlagged) }
        if let ids = args.values["--item"] {
            for id in ids where !result.items.contains(where: { $0.id == id || $0.displayName == id }) {
                throw CLIError("no item \(id) in \(ruleID) (use `majortom scan --rule \(ruleID) --json` for ids)")
            }
            items = result.items.filter { ids.contains($0.id) || ids.contains($0.displayName) }
        }
        let sizes = Dictionary(items.map { ($0.id, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
        report = await engine.clean([CleanRequest(ruleID: ruleID, itemIDs: items.map(\.id))], sizes: sizes, execute: execute)
    }

    if json { try printJSON(report); return }
    print(execute ? "CLEAN \(rule.title) [\(rule.tier.label)]" : "DRY RUN — nothing will be touched. \(rule.title) [\(rule.tier.label)]")
    print(wrap("Impact: " + rule.impact, width: 100, indent: "  "))
    for o in report.outcomes {
        let status: String = switch o.status {
        case .wouldClean: "would \(o.method.summary)"
        case .cleaned: "done: \(o.method.summary)"
        case .skipped(let why): "skipped: \(why)"
        case .failed(let why): "FAILED: \(why)"
        }
        print("  \(lpad(fmt(o.estimatedBytes), 9))  \(pad(o.displayName, 48))  \(status)")
    }
    print("Estimated: \(fmt(report.estimatedBytes))")
    if let r = report.reclaimedBytes { print("Measured free-space change: \(fmt(r))") }
    if !execute { print("Re-run with --execute to actually do this.") }
}

func historyCommand(_ args: Args) throws {
    let entries = HistoryLog().entries()
    if args.has("--json") { try printJSON(entries); return }
    if entries.isEmpty { print("No cleans yet. Ground Control has nothing to report."); return }
    for e in entries {
        print("\(e.date)  \(e.ruleIDs.joined(separator: ","))  \(e.items.count) items  reclaimed \(fmt(e.reclaimedBytes)) (est. \(fmt(e.estimatedBytes)))")
    }
}

struct ProjectsJSON: Encodable {
    struct Entry: Encodable {
        var project: Project
        var lastActivity: Date?
        var stale: Bool
        var pinned: Bool
        var strippableBytes: Int64
        var warnings: [String]
    }
    var scannedAt: Date
    var durationSeconds: Double
    var roots: [String]
    var staleAfterDays: Int
    var strippableBytes: Int64
    var staleStrippableBytes: Int64
    var projects: [Entry]
}

func projectsCommand(_ args: Args) async throws {
    let context = try makeContext()
    let settings = context.settings
    let scanner = ProjectScanner(context: context)
    let roots = settings.effectiveProjectRoots(home: context.home)
    let json = args.has("--json")
    if !json {
        FileHandle.standardError.write(Data("Looking for projects in \(roots.isEmpty ? "(no project folders — set them in the app's Settings → Projects)" : roots.joined(separator: ", "))\(settings.projectRootsAreAutomatic ? " (detected)" : "")…\n".utf8))
    }
    let start = Date()
    let discovered = await scanner.discover()
    let discoveredIn = Date().timeIntervalSince(start)
    var projects = await ProjectScanner.sized(discovered)
    let elapsed = Date().timeIntervalSince(start)
    projects.removeAll { settings.ignoredProjects.contains($0.path.path) }
    let pinned = Set(settings.pinnedProjects)
    func stale(_ p: Project) -> Bool { !pinned.contains(p.path.path) && p.isStale(afterDays: settings.staleAfterDays) }
    if args.has("--stale") { projects = projects.filter(stale) }
    let total = projects.reduce(Int64(0)) { $0 + $1.strippableSize }
    let staleTotal = projects.filter(stale).reduce(Int64(0)) { $0 + $1.strippableSize }

    if json {
        try printJSON(ProjectsJSON(
            scannedAt: start, durationSeconds: elapsed, roots: roots, staleAfterDays: settings.staleAfterDays,
            strippableBytes: total, staleStrippableBytes: staleTotal,
            projects: projects.map {
                .init(project: $0, lastActivity: $0.lastActivity, stale: stale($0), pinned: pinned.contains($0.path.path),
                      strippableBytes: $0.strippableSize, warnings: $0.warnings)
            }))
        return
    }

    let showDirs = args.has("--dirs")
    var lastRoot = ""
    for p in projects {
        if p.root.path != lastRoot {
            lastRoot = p.root.path
            print("\n== \(p.root.path.replacingOccurrences(of: context.home.path, with: "~")) ==")
        }
        let state = pinned.contains(p.path.path) ? "pinned" : (stale(p) ? "STALE" : "active")
        let when = p.lastActivity.map { dateFormatter.string(from: $0) } ?? "—"
        let warn = p.warnings.isEmpty ? "" : "  ! " + p.warnings.joined(separator: ", ")
        print("\(pad(state, 7)) \(pad(when, 11)) \(lpad(p.strippable.isEmpty ? "—" : fmt(p.strippableSize), 9))  \(p.relativePath)\(warn)")
        guard showDirs else { continue }
        for d in p.strippable {
            print("                             \(lpad(fmt(d.size), 9))  \(pad(d.relativePath, 40)) \(d.reason)")
        }
        for d in p.skipped {
            print("                             \(lpad("kept", 9))  \(pad(d.relativePath, 40)) \(d.reason)")
        }
        if !p.restoreCommands.isEmpty { print("                             restore: \(p.restoreCommands.joined(separator: "  then  "))") }
        for n in p.notes { print("                             note: \(n)") }
    }
    let staleCount = projects.filter(stale).count
    print("\n\(projects.count) projects, \(staleCount) stale (no activity for \(settings.staleAfterDays)+ days)")
    print("Strippable: \(fmt(total)) in all projects, \(fmt(staleTotal)) in stale ones")
    print(String(format: "Discovery %.1f s, sizing %.1f s", discoveredIn, elapsed - discoveredIn))
}

struct OffloadJSON: Encodable {
    var destination: String?
    var ready: Bool
    var status: String
    var fileSystem: String?
    var mountedFrom: String?
    var availableBytes: Int64?
    var incompleteCopies: [String]
    var offloaded: [OffloadRecord]
    var candidates: [OffloadCandidate]?
    var candidateBytes: Int64?
}

func offloadCommand(_ args: Args) async throws {
    let context = try makeContext(args)
    let settings = context.settings
    let engine = OffloadEngine(destination: settings.offloadDestinationURL, context: context)
    let check = engine.checkDestination()
    let records = engine.store.records()
    let partials = check.isReady ? (engine.destination.map { OffloadLayout.partials(in: $0) } ?? []).map(\.path) : []
    var candidates: [OffloadCandidate]?
    if args.has("--candidates") {
        if !args.has("--json") { FileHandle.standardError.write(Data("Looking for offload candidates…\n".utf8)) }
        candidates = await engine.candidates()
    }
    if args.has("--json") {
        try printJSON(OffloadJSON(destination: engine.destination?.path, ready: check.isReady, status: check.message,
                                  fileSystem: check.status?.fileSystem, mountedFrom: check.status?.mountedFrom,
                                  availableBytes: check.status?.availableBytes, incompleteCopies: partials,
                                  offloaded: records, candidates: candidates,
                                  candidateBytes: candidates.map { $0.reduce(0) { $0 + ($1.size ?? 0) } }))
        return
    }
    print("Destination: \(engine.destination?.path ?? "not set (choose a folder in the app's Settings → External)")")
    print("  \(check.isReady ? "ready" : "NOT READY"): \(check.message)")
    for p in partials { print("  incomplete copy: \(p)") }
    print("\nOffloaded (\(records.count)):")
    for r in records {
        let m = r.manifest
        let state: String
        switch r.original {
        case .trashed(let d): state = "original trashed \(dateFormatter.string(from: d))"
        case .kept(let why): state = "original kept: \(why)"
        }
        print("  \(dateFormatter.string(from: m.createdAt))  \(lpad(fmt(m.payloadBytes), 9))  \(m.displayName)  [\(m.kind.rawValue)]")
        print("      \(m.archivePath)")
        print("      \(state)\(r.restores.isEmpty ? "" : "; restored \(r.restores.count)×")")
        print("      restore: \(m.restoreCommand)")
    }
    guard let candidates else { return }
    let home = context.home.path
    for kind in OffloadKind.allCases {
        let list = candidates.filter { $0.kind == kind }
        let total = list.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        print("\n== \(kind.title): \(list.count), \(fmt(total)) ==")
        for c in list {
            let used = c.lastUsed.map { dateFormatter.string(from: $0) } ?? "—"
            let extra = c.shouldHibernateFirst ? "  (hibernate first: \(fmt(c.strippableBytes)) of deps/build)" : ""
            print("  \(lpad(fmt(c.size), 9))  \(pad(used, 10))  \(c.path.path.replacingOccurrences(of: home, with: "~"))\(extra)")
        }
    }
    let total = candidates.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    print("\n\(candidates.count) candidates, \(fmt(total))")
}

do {
    let args = try Args(CommandLine.arguments)
    switch args.command {
    case "scan": try await scanCommand(args)
    case "rules": try rulesCommand(args)
    case "clean": try await cleanCommand(args)
    case "history": try historyCommand(args)
    case "projects": try await projectsCommand(args)
    case "offload": try await offloadCommand(args)
    case "map": mapCommand(args)
    case "compare": compareCommand(args)
    case "help", "--help", "-h": print(usage)
    default: throw CLIError("unknown command: \(args.command)\n\n\(usage)")
    }
} catch let e as CLIError {
    FileHandle.standardError.write(Data((e.message + "\n").utf8))
    exit(2)
}


func mapCommand(_ args: Args) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let root = args.values["--path"]?.first.map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? home
    guard let map = SpaceMapScanner(root: root, home: home).scan() else {
        print("Not a readable folder: \(root.path)")
        return
    }
    print("\(root.path): \(ByteFormat.string(map.root.size)) in \(map.fileCount) files, "
        + String(format: "%.1f s", map.duration) + (map.unreadableFolders > 0 ? ", \(map.unreadableFolders) folders unreadable" : ""))
    print("\nBy kind")
    for kind in FileKind.allCases.sorted(by: { map.root.bytes(of: $0) > map.root.bytes(of: $1) }) where map.root.bytes(of: kind) > 0 {
        print("  \(kind.title.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormat.string(map.root.bytes(of: kind)))")
    }
    print("\nWhere it comes from")
    for o in map.origins.prefix(25) {
        print("  \(o.origin.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(ByteFormat.string(o.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(o.fileCount) files")
    }
    print("\nBiggest folders")
    for child in map.root.children.prefix(12) {
        print("  \(child.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(ByteFormat.string(child.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.kind.title)\(child.origin.map { " · " + $0.name } ?? "")")
    }
}

func compareCommand(_ args: Args) {
    guard let from = args.values["--from"]?.first, let to = args.values["--to"]?.first else {
        print("compare needs --from <folder> and --to <backup folder>")
        return
    }
    let link = FolderLink(name: "compare", source: (from as NSString).expandingTildeInPath,
                          destination: (to as NSString).expandingTildeInPath)
    let report = LinkScanner.report(link)
    if !report.destinationConnected { print("The backup drive isn't connected: only the local side is shown.") }
    for e in report.entries {
        let days = e.daysUntouched().map { "\($0) d" } ?? "—"
        print("  \(e.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(ByteFormat.string(e.localBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(days.padding(toLength: 7, withPad: " ", startingAt: 0)) \(e.name)"
            + (e.isOffloadCandidate(afterDays: link.offloadAfterDays) ? "   ← could be offloaded" : ""))
    }
    print("\(ByteFormat.string(report.backedUpBytes)) backed up, \(ByteFormat.string(report.pendingBytes)) not yet (\(report.pendingCount) files)")
}
