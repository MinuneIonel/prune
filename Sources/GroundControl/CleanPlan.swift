import Foundation
import MajorTomCore

public struct ItemKey: Hashable, Sendable {
    public var ruleID: String
    public var itemID: String

    public init(ruleID: String, itemID: String) {
        self.ruleID = ruleID
        self.itemID = itemID
    }
}

/// Exactly what a clean will do, grouped by rule, built from the current selection.
public struct CleanPlan: Sendable {
    public struct Group: Sendable, Identifiable {
        public var id: String { ruleID }
        public var ruleID: String
        public var title: String
        public var tier: Tier
        public var impact: String
        public var recovery: String
        public var regenCost: String
        public var items: [Item]
        public var actions: [RuleAction]
        /// Shown prominently in the review (e.g. uncommitted work in a project being hibernated).
        public var warnings: [String] = []
        /// Extra information (e.g. restore commands, pnpm hard links).
        public var notes: [String] = []

        public var estimatedBytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    public var groups: [Group]

    public var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty && $0.actions.isEmpty } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var actionCount: Int { groups.reduce(0) { $0 + $1.actions.count } }
    public var estimatedBytes: Int64 { groups.reduce(0) { $0 + $1.estimatedBytes } }

    public var estimatedBytesByTier: [Tier: Int64] {
        groups.reduce(into: [:]) { $0[$1.tier, default: 0] += $1.estimatedBytes }
    }

    /// Items that end up in the Trash rather than being deleted outright.
    public var trashedItemCount: Int {
        groups.reduce(0) { $0 + $1.items.filter { $0.methodOverride == .trash }.count }
    }

    public var requests: [CleanRequest] {
        groups.filter { !$0.items.isEmpty }.map { CleanRequest(ruleID: $0.ruleID, itemIDs: $0.items.map(\.id)) }
    }

    /// True when the plan hibernates at least one project.
    public var hibernatesProjects: Bool { groups.contains { ProjectHibernation.isHibernationRule($0.ruleID) } }

    public var actionRequests: [ActionRequest] {
        groups.flatMap { g in g.actions.map { ActionRequest(ruleID: g.ruleID, actionID: $0.id) } }
    }

    public var sizes: [String: Int64] {
        var out: [String: Int64] = [:]
        for g in groups { for item in g.items { out[item.id] = item.size ?? 0 } }
        return out
    }
}

/// The review -> confirm -> progress -> result flow shown in the clean sheet.
public struct CleanSession: Sendable {
    public enum Phase: Sendable {
        /// Waiting for the user. `dryRun` is filled in once the engine has re-checked every item.
        case reviewing(dryRun: CleanReport?)
        case cleaning(completed: Int, total: Int, current: String)
        case finished(CleanReport)
    }

    public var plan: CleanPlan
    public var phase: Phase

    /// Dry-run outcome for an item, once known.
    public func dryRunStatus(ruleID: String, itemID: String) -> CleanOutcome.Status? {
        guard case .reviewing(let report?) = phase else { return nil }
        return report.outcomes.first { $0.ruleID == ruleID && $0.itemID == itemID }?.status
    }

    public func dryRunStatus(ruleID: String, actionID: String) -> CleanOutcome.Status? {
        dryRunStatus(ruleID: ruleID, itemID: "action:" + actionID)
    }

    /// Bytes the dry run says will actually go (skipped items excluded).
    public var confirmedEstimate: Int64? {
        guard case .reviewing(let report?) = phase else { return nil }
        return report.estimatedBytes
    }

    public var canConfirm: Bool {
        guard case .reviewing(let report?) = phase else { return false }
        return report.outcomes.contains { $0.status == .wouldClean }
    }
}
