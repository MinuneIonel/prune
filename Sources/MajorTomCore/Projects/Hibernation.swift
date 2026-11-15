import Foundation

/// Hibernation = deleting a project's dependency and build directories (nothing else), via the normal clean engine.
///
/// Each project gets its own rule (`hibernate:<path>`) whose base directory is the project itself and whose resolver
/// re-analyses the project from scratch, so the engine only ever deletes directories that are strippable *right now*:
/// never source, `.git`, `.env*`, anything tracked by git, nested repos, or pinned/ignored projects.
public enum ProjectHibernation {
    public static let rulePrefix = "hibernate:"

    public static func ruleID(for path: URL) -> String { rulePrefix + path.standardizedFileURL.path }

    public static func projectPath(ruleID: String) -> URL? {
        guard ruleID.hasPrefix(rulePrefix) else { return nil }
        return URL(filePath: String(ruleID.dropFirst(rulePrefix.count)), directoryHint: .isDirectory)
    }

    public static func isHibernationRule(_ ruleID: String) -> Bool { ruleID.hasPrefix(rulePrefix) }

    /// The rule for one project. `project` (from a scan) only supplies display copy; resolution is always fresh.
    public static func rule(path: URL, project: Project? = nil, git: any CommandRunner = ProcessRunner()) -> Rule {
        let path = path.standardizedFileURL
        let name = path.lastPathComponent
        let impact = "Only the folders listed are deleted; source, .git, .env* and git-tracked files stay."
        let pods = project?.strippable.contains { $0.kind == .pods } ?? false
        let deps = project?.strippable.contains { $0.kind.isDependency } ?? true
        return Rule(
            id: ruleID(for: path),
            title: "Hibernate \(name)",
            category: .projects,
            tier: .costsTime,
            impact: impact,
            recovery: project?.restoreSummary ?? "Reinstall dependencies with the project's package manager.",
            regenCost: pods ? "reinstall, pod install, first build" : (deps ? "reinstall and first build" : "a full first build"),
            method: .delete,
            baseDirectories: { _ in [path] },
            resolve: { ctx in
                let settings = ctx.settings
                guard !settings.pinnedProjects.contains(path.path), !settings.ignoredProjects.contains(path.path) else { return [] }
                let scanner = ProjectScanner(context: ctx, git: git)
                guard let fresh = await scanner.analyze(projectAt: path) else { return [] }
                return fresh.strippable.map {
                    Item(id: $0.path.path, displayName: "\(name)/\($0.relativePath)", path: $0.path, note: $0.reason)
                }
            })
    }
}

/// A finished hibernation: what went and how to get it back.
public struct HibernationRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var projectPath: String
    /// Removed directories, relative to the project.
    public var removed: [String]
    public var estimatedBytes: Int64
    public var restoreCommands: [String]

    public init(id: UUID = UUID(), date: Date = Date(), projectPath: String, removed: [String], estimatedBytes: Int64,
                restoreCommands: [String]) {
        self.id = id
        self.date = date
        self.projectPath = projectPath
        self.removed = removed
        self.estimatedBytes = estimatedBytes
        self.restoreCommands = restoreCommands
    }

    /// Records for every project in `report` that had at least one directory removed.
    public static func records(from report: CleanReport, projects: [Project], date: Date = Date()) -> [HibernationRecord] {
        guard !report.dryRun else { return [] }
        let byRule = Dictionary(grouping: report.outcomes.filter {
            ProjectHibernation.isHibernationRule($0.ruleID) && $0.status == .cleaned
        }, by: \.ruleID)
        return byRule.keys.sorted().compactMap { ruleID in
            guard let path = ProjectHibernation.projectPath(ruleID: ruleID)?.standardizedFileURL,
                  let outcomes = byRule[ruleID], !outcomes.isEmpty else { return nil }
            let project = projects.first { $0.path.path == path.path }
            let removed = outcomes.compactMap { o in
                o.path.map { $0.hasPrefix(path.path + "/") ? String($0.dropFirst(path.path.count + 1)) : $0 }
            }
            return HibernationRecord(date: date, projectPath: path.path, removed: removed,
                                     estimatedBytes: outcomes.reduce(0) { $0 + ($1.estimatedBytes ?? 0) },
                                     restoreCommands: project?.restoreCommands ?? [])
        }
    }
}

/// Append-only JSON-lines log of hibernations (`hibernations.jsonl` next to the history log).
public final class HibernationLog: Sendable {
    public let url: URL

    public init(url: URL = AppSupport.directory().appending(path: "hibernations.jsonl")) {
        self.url = url
    }

    public func append(_ records: [HibernationRecord]) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var data = Data()
        for r in records {
            data.append(try enc.encode(r))
            data.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Oldest first; malformed lines skipped.
    public func entries() -> [HibernationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? dec.decode(HibernationRecord.self, from: Data($0)) }
    }

    /// Newest record per project path.
    public func latestByProject() -> [String: HibernationRecord] {
        entries().reduce(into: [:]) { $0[$1.projectPath] = $1 }
    }
}
