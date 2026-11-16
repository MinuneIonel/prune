import Foundation
import MajorTomCore
import Observation
import Synchronization

/// A backup, offload or bring-back in one of its three stages.
public struct LinkRun: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Waiting for the user to confirm.
        case confirm
        case running(LinkProgress)
        case finished(LinkRunReport)
    }

    public var link: FolderLink
    public var action: LinkRunReport.Action
    /// Top-level items it covers; nil = everything that needs it.
    public var entries: [String]?
    public var bytes: Int64
    public var files: Int
    public var phase: Phase = .confirm

    public var isRunning: Bool { if case .running = phase { true } else { false } }
}

/// Linked folders: which of your work is on the backup drive, what still needs copying, what could leave this Mac.
@MainActor
@Observable
public final class LinksModel {
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var cancel: CancellationFlag?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public private(set) var links: [FolderLink]
    public private(set) var reports: [UUID: LinkReport] = [:]
    public private(set) var comparing: Set<UUID> = []
    public var selectedLinkID: UUID?
    /// Names of the selected link's checked items.
    public var checked: Set<String> = []
    public private(set) var run: LinkRun?
    /// Hash every byte on both sides before anything leaves this Mac.
    public var thoroughVerification = false
    public private(set) var message: String?

    public init(environment: AppEnvironment) {
        self.environment = environment
        links = environment.linkStore.load()
        selectedLinkID = links.first?.id
        for link in links {
            if let last = environment.linkStore.lastReport(link.id) { reports[link.id] = last }
        }
    }

    public var selectedLink: FolderLink? { links.first { $0.id == selectedLinkID } ?? links.first }
    public var isComparing: Bool { !comparing.isEmpty }

    /// Bytes that could leave this Mac across all links: fully backed up and untouched long enough.
    public var offloadableBytes: Int64 {
        links.reduce(0) { sum, link in
            sum + (reports[link.id]?.offloadCandidates(afterDays: link.offloadAfterDays).reduce(0) { $0 + $1.localBytes } ?? 0)
        }
    }

    public var pendingBytes: Int64 { links.reduce(0) { $0 + (reports[$1.id]?.pendingBytes ?? 0) } }

    // MARK: Editing links

    private func persist() {
        do { try environment.linkStore.save(links) } catch { message = "Couldn't save the links: \(error.localizedDescription)" }
    }

    /// Nil when the pair is fine; otherwise why it can't be linked.
    public func problem(source: URL, destination: URL) -> String? {
        let s = source.resolvingSymlinksInPath().path, d = destination.resolvingSymlinksInPath().path
        if s == d { return "Choose two different folders." }
        if s.hasPrefix(d + "/") || d.hasPrefix(s + "/") { return "One folder is inside the other." }
        if links.contains(where: { $0.source == source.path(percentEncoded: false) && $0.destination == destination.path(percentEncoded: false) }) {
            return "These two folders are already linked."
        }
        return nil
    }

    @discardableResult
    public func addLink(name: String, source: URL, destination: URL, offloadAfterDays: Int = 60) -> FolderLink? {
        guard problem(source: source, destination: destination) == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let link = FolderLink(name: trimmed.isEmpty ? source.lastPathComponent : trimmed,
                              source: source.standardizedFileURL.path(percentEncoded: false),
                              destination: destination.standardizedFileURL.path(percentEncoded: false),
                              offloadAfterDays: offloadAfterDays)
        links.append(link)
        persist()
        selectedLinkID = link.id
        checked = []
        Task { await compare(link) }
        return link
    }

    /// Forgets the link. Neither folder is touched.
    public func removeLink(_ link: FolderLink) {
        links.removeAll { $0.id == link.id }
        reports[link.id] = nil
        environment.linkStore.forget(link.id)
        persist()
        if selectedLinkID == link.id { selectedLinkID = links.first?.id; checked = [] }
    }

    public func setOffloadAfterDays(_ days: Int, for link: FolderLink) {
        guard let i = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[i].offloadAfterDays = max(1, days)
        persist()
    }

    public func select(_ link: FolderLink) {
        guard selectedLinkID != link.id else { return }
        selectedLinkID = link.id
        checked = []
    }

    // MARK: Comparing

    public func compare(_ link: FolderLink) async {
        guard !comparing.contains(link.id) else { return }
        comparing.insert(link.id)
        let previous = reports[link.id] ?? environment.linkStore.lastReport(link.id)
        let report = await Task.detached(priority: .userInitiated) { LinkScanner.report(link, previous: previous) }.value
        comparing.remove(link.id)
        guard links.contains(where: { $0.id == link.id }) else { return }
        reports[link.id] = report
        // Only a real comparison is worth remembering for the days the drive is away.
        if report.destinationConnected { environment.linkStore.remember(report) }
        if link.id == selectedLink?.id {
            let names = Set(report.entries.map(\.name))
            checked = checked.intersection(names)
        }
    }

    public func compareAll() async {
        for link in links { await compare(link) }
    }

    /// Checks every item of the link that is safely on the backup and hasn't been touched for long enough.
    public func checkOffloadCandidates(_ link: FolderLink) {
        checked = Set(reports[link.id]?.offloadCandidates(afterDays: link.offloadAfterDays).map(\.name) ?? [])
    }

    public func checkedEntries(_ link: FolderLink) -> [LinkEntry] {
        reports[link.id]?.entries.filter { checked.contains($0.name) } ?? []
    }

    /// Checked items that can leave this Mac right now.
    public func offloadable(_ link: FolderLink) -> [LinkEntry] {
        checkedEntries(link).filter { $0.state == .backedUp && !$0.remembered && $0.localBytes > 0 }
    }

    // MARK: Acting (always: confirm first)

    public func reviewBackUp(_ link: FolderLink) {
        guard run == nil, let report = reports[link.id], report.destinationConnected, report.pendingCount > 0 else { return }
        run = LinkRun(link: link, action: .backUp, entries: nil, bytes: report.pendingBytes, files: report.pendingCount)
    }

    public func reviewOffload(_ link: FolderLink) {
        let entries = offloadable(link)
        guard run == nil, !entries.isEmpty else { return }
        run = LinkRun(link: link, action: .offload, entries: entries.map(\.name),
                      bytes: entries.reduce(0) { $0 + $1.localBytes }, files: entries.reduce(0) { $0 + $1.localCount })
    }

    public func reviewBringBack(_ link: FolderLink, entry: LinkEntry) {
        guard run == nil, entry.backupOnlyCount > 0, reports[link.id]?.destinationConnected == true else { return }
        run = LinkRun(link: link, action: .bringBack, entries: [entry.name], bytes: entry.backupOnlyBytes,
                      files: entry.backupOnlyCount)
    }

    public func confirmRun() async {
        guard var current = run, current.phase == .confirm else { return }
        let flag = CancellationFlag()
        cancel = flag
        let engine = LinkEngine(link: current.link, home: environment.context.home, remover: environment.remover,
                                history: environment.history, thorough: thoroughVerification, cancel: flag)
        current.phase = .running(LinkProgress(totalBytes: current.bytes, totalFiles: current.files))
        run = current
        let latest = Mutex<LinkProgress?>(nil)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                if let p = latest.withLock({ $0 }), self.run?.isRunning == true { self.run?.phase = .running(p) }
            }
        }
        let action = current.action, entries = current.entries
        let report = await Task.detached(priority: .userInitiated) { () -> LinkRunReport in
            let progress: @Sendable (LinkProgress) -> Void = { p in latest.withLock { $0 = p } }
            switch action {
            case .backUp: return engine.backUp(entries: entries, execute: true, progress: progress)
            case .offload: return engine.offload(entries: entries ?? [], execute: true, progress: progress)
            case .bringBack: return engine.bringBack(entries: entries ?? [], execute: true, progress: progress)
            }
        }.value
        ticker.cancel()
        cancel = nil
        run?.phase = .finished(report)
        if action == .offload { checked.subtract(report.outcomes.filter(\.succeeded).map(\.name)) }
        await compare(current.link)
    }

    public func cancelRun() {
        if run?.isRunning == true { cancel?.cancel() } else { run = nil }
    }

    public func dismissRun() {
        guard run?.isRunning != true else { return }
        run = nil
    }
}
