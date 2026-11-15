import Foundation

public enum ScanEvent: Sendable {
    case started(ruleCount: Int)
    case ruleStarted(ruleID: String)
    case ruleFinished(RuleResult)
    case finished(duration: TimeInterval)
}

/// Limits how many blocking file-system walks run at once.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { available = permits }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let value = await body()
        release()
        return value
    }
}

/// Resolves and sizes rules. Results are cached per session; rescanning one rule leaves the others alone.
public actor Scanner {
    public let rules: [Rule]
    public private(set) var context: RuleContext
    private var cache: [String: RuleResult] = [:]
    private let limiter = AsyncLimiter(max(4, ProcessInfo.processInfo.activeProcessorCount))

    public init(rules: [Rule] = RuleCatalogue.all, context: RuleContext = RuleContext()) {
        self.rules = rules
        self.context = context
    }

    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    /// New settings for later scans (e.g. changed file-size thresholds). Cached results stay until rescanned.
    public func update(settings: Settings) {
        context.settings = settings
    }

    public func cachedResult(for ruleID: String) -> RuleResult? { cache[ruleID] }

    /// Cached results in catalogue order.
    public var cachedResults: [RuleResult] { rules.compactMap { cache[$0.id] } }

    public func invalidate(ruleID: String? = nil) {
        if let ruleID { cache[ruleID] = nil } else { cache.removeAll() }
    }

    /// Scans every rule concurrently. Hard-linked inodes are counted once across the whole scan.
    @discardableResult
    public func scanAll(progress: (@Sendable (ScanEvent) -> Void)? = nil) async -> [RuleResult] {
        await scan(ruleIDs: rules.map(\.id), progress: progress)
    }

    /// Scans the given rules with one shared inode tracker and caches the results.
    @discardableResult
    public func scan(ruleIDs: [String], progress: (@Sendable (ScanEvent) -> Void)? = nil) async -> [RuleResult] {
        let selected = rules.filter { ruleIDs.contains($0.id) }
        let start = Date()
        progress?(.started(ruleCount: selected.count))
        let tracker = InodeTracker()
        let context = self.context
        let limiter = self.limiter
        let results = await withTaskGroup(of: RuleResult.self) { group in
            for rule in selected {
                group.addTask {
                    progress?(.ruleStarted(ruleID: rule.id))
                    let r = await Self.scanRule(rule, context: context, tracker: tracker, limiter: limiter)
                    progress?(.ruleFinished(r))
                    return r
                }
            }
            var out: [RuleResult] = []
            for await r in group { out.append(r) }
            return out
        }
        if !Task.isCancelled {
            for r in results { cache[r.ruleID] = r }
        }
        progress?(.finished(duration: Date().timeIntervalSince(start)))
        let order = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1.id, $0) })
        return results.sorted { (order[$0.ruleID] ?? 0) < (order[$1.ruleID] ?? 0) }
    }

    /// Rescans a single rule (fresh inode tracker) and replaces its cached result.
    public func rescan(ruleID: String) async -> RuleResult? {
        await scan(ruleIDs: [ruleID]).first
    }

    static func scanRule(_ rule: Rule, context: RuleContext, tracker: InodeTracker, limiter: AsyncLimiter) async -> RuleResult {
        let start = Date()
        var (items, errorText, denied) = await rule.resolveItems(context)
        // Make every item self-describing: methodOverride holds the effective method after a scan.
        for i in items.indices where items[i].methodOverride == nil { items[i].methodOverride = rule.method }

        items = await withTaskGroup(of: (Int, Item).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    var item = item
                    guard let path = item.path else { return (index, item) }
                    if item.size == nil {
                        let paths = [path] + item.companionPaths
                        var total: Int64 = 0
                        var newest: Date?
                        for p in paths {
                            if Task.isCancelled { break }
                            if let r = await limiter.run({ await DiskSizer.size(of: p, tracker: tracker) }) {
                                total += r.allocatedBytes
                                if let d = r.lastUsed { newest = max(newest ?? d, d) }
                            }
                        }
                        item.size = total
                        if item.lastUsed == nil { item.lastUsed = newest }
                    } else if item.lastUsed == nil {
                        item.lastUsed = DiskSizer.lastUsed(of: path)
                    }
                    return (index, item)
                }
            }
            var sized = items
            for await (i, item) in group { sized[i] = item }
            return sized
        }
        items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        return RuleResult(
            ruleID: rule.id,
            items: items,
            actions: rule.actions(context, items),
            duration: Date().timeIntervalSince(start),
            error: errorText,
            scannedAt: Date(),
            deniedPaths: denied
        )
    }
}

extension Scanner {
    /// Streaming variant for UIs: yields events as rules finish.
    public nonisolated func events() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.scanAll { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
