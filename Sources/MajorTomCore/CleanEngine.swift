import Darwin
import Foundation

public struct CleanRequest: Sendable {
    public var ruleID: String
    /// Item IDs to clean. They are matched against a fresh resolution of the rule; anything else is refused.
    public var itemIDs: [String]

    public init(ruleID: String, itemIDs: [String]) {
        self.ruleID = ruleID
        self.itemIDs = itemIDs
    }
}

/// A rule-level action to run as part of a clean (e.g. `pnpm store prune`).
public struct ActionRequest: Sendable, Hashable {
    public var ruleID: String
    public var actionID: String

    public init(ruleID: String, actionID: String) {
        self.ruleID = ruleID
        self.actionID = actionID
    }
}

/// Progress of a clean, reported after each item or action is handled.
public struct CleanProgress: Sendable {
    public var completed: Int
    public var total: Int
    /// Display name of the item/action just handled.
    public var current: String
    public var outcome: CleanOutcome
}

public struct CleanOutcome: Sendable, Codable {
    public enum Status: Sendable, Codable, Equatable {
        case wouldClean
        case cleaned
        case skipped(String)
        case failed(String)
    }

    public var ruleID: String
    public var itemID: String
    public var displayName: String
    public var path: String?
    public var method: CleanMethod
    public var estimatedBytes: Int64?
    public var status: Status
}

public struct CleanReport: Sendable, Codable {
    public var dryRun: Bool
    public var outcomes: [CleanOutcome]
    /// Sum of scan estimates for items that were (or would be) cleaned.
    public var estimatedBytes: Int64
    /// Measured change in free space; nil for dry runs.
    public var reclaimedBytes: Int64?
}

/// Executes cleans. Everything defaults to a dry run; a real clean needs `execute: true`.
public struct CleanEngine: Sendable {
    public var rules: [Rule]
    public var context: RuleContext
    public var history: HistoryLog
    public var validator: PathValidator
    /// Free-space probe (injectable for tests).
    public var freeSpace: @Sendable () -> Int64
    /// Runs the read-only git queries behind project hibernation rules.
    public var git: any CommandRunner
    /// Performs the actual delete / move-to-Trash (fixture mode and tests use a folder instead of the real Trash).
    public var remover: any FileRemover

    public init(rules: [Rule] = RuleCatalogue.all,
                context: RuleContext = RuleContext(),
                history: HistoryLog = HistoryLog(),
                freeSpace: (@Sendable () -> Int64)? = nil,
                git: any CommandRunner = ProcessRunner(),
                remover: any FileRemover = SystemFileRemover()) {
        self.git = git
        self.remover = remover
        self.rules = rules
        self.context = context
        self.history = history
        self.validator = PathValidator(context: context)
        let home = context.home
        self.freeSpace = freeSpace ?? { VolumeInfo.availableBytes(at: home) ?? 0 }
    }

    /// Cleans items and runs rule-level actions (actions first). `sizes` lets the caller pass scan estimates
    /// (by item ID) for reporting. One measured report and one history entry cover the whole batch.
    public func clean(_ requests: [CleanRequest], actions: [ActionRequest] = [], sizes: [String: Int64] = [:],
                      execute: Bool = false, progress: (@Sendable (CleanProgress) -> Void)? = nil) async -> CleanReport {
        var outcomes: [CleanOutcome] = []
        let before = execute ? freeSpace() : 0
        let total = actions.count + requests.reduce(0) { $0 + $1.itemIDs.count }
        func record(_ o: CleanOutcome) {
            outcomes.append(o)
            progress?(CleanProgress(completed: outcomes.count, total: total, current: o.displayName, outcome: o))
        }

        for request in actions {
            record(await actionOutcome(ruleID: request.ruleID, actionID: request.actionID, execute: execute))
        }

        for request in requests {
            guard let rule = rule(id: request.ruleID) else {
                for id in request.itemIDs {
                    record(CleanOutcome(ruleID: request.ruleID, itemID: id, displayName: id, path: nil, method: .reportOnly,
                                        estimatedBytes: nil, status: .skipped("unknown rule")))
                }
                continue
            }
            // Only paths produced by the rule's own resolver, resolved right now.
            let fresh = await rule.resolveItems(context).items
            let bases = rule.baseDirectories(context)
            for itemID in request.itemIDs {
                guard let item = fresh.first(where: { $0.id == itemID }) else {
                    record(CleanOutcome(ruleID: rule.id, itemID: itemID, displayName: itemID, path: nil,
                                        method: .reportOnly, estimatedBytes: sizes[itemID],
                                        status: .skipped("not produced by the rule's resolver (gone, or never matched)")))
                    continue
                }
                let method = rule.method(for: item)
                var outcome = CleanOutcome(ruleID: rule.id, itemID: item.id, displayName: item.displayName,
                                           path: item.path?.path, method: method,
                                           estimatedBytes: sizes[itemID] ?? item.size, status: .wouldClean)
                outcome.status = await perform(item: item, method: method, bases: bases, trashOnly: rule.isTrashOnly,
                                               execute: execute)
                record(outcome)
            }
        }
        let ruleIDs = requests.map(\.ruleID) + actions.map(\.ruleID)
        return await finish(outcomes: outcomes, ruleIDs: ruleIDs, before: before, execute: execute)
    }

    /// A catalogue rule, or the per-project hibernation rule for `hibernate:<path>` IDs.
    public func rule(id: String) -> Rule? {
        if let r = rules.first(where: { $0.id == id }) { return r }
        if let path = ProjectHibernation.projectPath(ruleID: id) { return ProjectHibernation.rule(path: path, git: git) }
        return nil
    }

    /// Runs a rule-level action (e.g. `pnpm store prune`). Dry run unless `execute`.
    public func runAction(ruleID: String, actionID: String, execute: Bool = false) async -> CleanReport {
        await clean([], actions: [ActionRequest(ruleID: ruleID, actionID: actionID)], execute: execute)
    }

    private func actionOutcome(ruleID: String, actionID: String, execute: Bool) async -> CleanOutcome {
        var outcome = CleanOutcome(ruleID: ruleID, itemID: "action:" + actionID, displayName: actionID, path: nil,
                                   method: .reportOnly, estimatedBytes: nil, status: .skipped("unknown action"))
        guard let rule = rule(id: ruleID) else {
            outcome.status = .skipped("unknown rule")
            return outcome
        }
        let fresh = await rule.resolveItems(context).items
        guard let action = rule.actions(context, fresh).first(where: { $0.id == actionID }) else { return outcome }
        outcome.displayName = action.title
        outcome.method = .command(action.command)
        if !action.runnable {
            outcome.status = .skipped("run it yourself: \(action.commandLine)")
        } else if !execute {
            outcome.status = .wouldClean
        } else {
            outcome.status = await runCommand(action.command)
        }
        return outcome
    }

    private func finish(outcomes: [CleanOutcome], ruleIDs: [String], before: Int64, execute: Bool) async -> CleanReport {
        let counted: Set<CleanOutcome.Status> = execute ? [.cleaned] : [.wouldClean]
        let estimate = outcomes.filter { counted.contains($0.status) }.reduce(Int64(0)) { $0 + ($1.estimatedBytes ?? 0) }
        guard execute else {
            return CleanReport(dryRun: true, outcomes: outcomes, estimatedBytes: estimate, reclaimedBytes: nil)
        }
        let reclaimed = freeSpace() - before
        let attempted = outcomes.filter { if case .skipped = $0.status { false } else { true } }
        if !attempted.isEmpty {
            let entry = HistoryEntry(
                id: UUID(), date: Date(), ruleIDs: Array(Set(ruleIDs)).sorted(),
                items: attempted.map {
                    var error: String?
                    if case .failed(let e) = $0.status { error = e }
                    return HistoryEntry.ItemRecord(ruleID: $0.ruleID, itemID: $0.itemID, displayName: $0.displayName,
                                                   path: $0.path, method: $0.method.summary,
                                                   estimatedBytes: $0.estimatedBytes, succeeded: $0.status == .cleaned,
                                                   error: error)
                },
                estimatedBytes: estimate, reclaimedBytes: reclaimed)
            try? history.append(entry)
        }
        return CleanReport(dryRun: false, outcomes: outcomes, estimatedBytes: estimate, reclaimedBytes: reclaimed)
    }

    private func perform(item: Item, method: CleanMethod, bases: [URL], trashOnly: Bool,
                         execute: Bool) async -> CleanOutcome.Status {
        if item.isProtected { return .skipped("protected: \(item.note ?? "never offered")") }
        if trashOnly, method != .trash {
            return .skipped("refused: this rule only ever moves items to the Trash (got \(method.summary))")
        }
        switch method {
        case .reportOnly:
            return .skipped("report only")
        case .command(let argv):
            return execute ? await runCommand(argv) : .wouldClean
        case .delete, .trash:
            guard let path = item.path else { return .skipped("no path") }
            let paths = [path] + item.companionPaths
            do {
                for p in paths {
                    try validator.validate(p, bases: bases)
                    if trashOnly { try validator.validateUserFile(p, bases: bases) }
                }
            } catch {
                return .skipped("refused: \(error.description)")
            }
            guard execute else { return .wouldClean }
            do {
                for p in paths {
                    // Re-validate right before touching each path.
                    try validator.validate(p, bases: bases)
                    if trashOnly {
                        try validator.validateUserFile(p, bases: bases)
                        try remover.trash(p)
                    } else if method == .delete {
                        try remover.delete(p)
                    } else {
                        try remover.trash(p)
                    }
                }
                return .cleaned
            } catch let e as PathValidationError {
                return .skipped("refused: \(e.description)")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func runCommand(_ argv: [String]) async -> CleanOutcome.Status {
        guard let result = await context.runner.run(argv, timeout: 600) else {
            return .failed("\(argv.first ?? "") not found")
        }
        if result.succeeded { return .cleaned }
        let msg = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(result.timedOut ? "timed out" : (msg.isEmpty ? "exit \(result.exitCode)" : msg))
    }
}

extension CleanOutcome.Status: Hashable {}

/// The only two ways the engine removes a path.
public protocol FileRemover: Sendable {
    func delete(_ url: URL) throws
    func trash(_ url: URL) throws
}

/// The real thing: `removeItem` / Finder's Trash.
public struct SystemFileRemover: FileRemover {
    public init() {}
    public func delete(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}

/// "Trash" = move into a given folder. Fixture mode and tests use it so they never fill the user's real Trash.
public struct FolderTrashRemover: FileRemover {
    public let trashFolder: URL
    public init(trashFolder: URL) { self.trashFolder = trashFolder }

    public func delete(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    public func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        var dest = trashFolder.appending(path: url.lastPathComponent)
        var n = 2
        while FS.exists(dest) {
            dest = trashFolder.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n)"
                + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dest)
    }
}

public enum VolumeInfo {
    /// Free bytes on the volume containing `url` (statfs; excludes purgeable space so before/after is honest).
    public static func availableBytes(at url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    public static func totalBytes(at url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        return Int64(fs.f_blocks) * Int64(fs.f_bsize)
    }
}
