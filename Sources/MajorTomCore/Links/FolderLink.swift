import Darwin
import Foundation

/// A working folder on this Mac paired with its copy on another drive. Prune compares the two,
/// copies what's missing, and can free the local copy of things that are safely on the other side.
public struct FolderLink: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Absolute path of the working folder.
    public var source: String
    /// Absolute path of the backup folder (usually on an external drive).
    public var destination: String
    /// Backed-up items untouched for this many days are suggested for offloading.
    public var offloadAfterDays: Int

    public init(id: UUID = UUID(), name: String, source: String, destination: String, offloadAfterDays: Int = 60) {
        self.id = id
        self.name = name
        self.source = source
        self.destination = destination
        self.offloadAfterDays = offloadAfterDays
    }

    public var sourceURL: URL { URL(filePath: source, directoryHint: .isDirectory) }
    public var destinationURL: URL { URL(filePath: destination, directoryHint: .isDirectory) }

    /// True when the drive holding the backup folder is there. For `/Volumes/Drive/…` that means the volume is
    /// mounted (the folder itself may not exist yet); elsewhere, that the folder's parent exists.
    public var destinationConnected: Bool {
        let parts = destination.split(separator: "/").map(String.init)
        let anchor: String
        if parts.count >= 2, parts[0] == "Volumes" {
            anchor = "/Volumes/" + parts[1]
        } else {
            anchor = destinationURL.deletingLastPathComponent().path(percentEncoded: false)
        }
        return FS.isDirectory(URL(filePath: anchor))
    }
}

/// How one file compares with its copy.
public enum FileBackupStatus: String, Codable, Sendable {
    /// Same size and date on both sides.
    case backedUp
    /// Not on the backup at all.
    case missing
    /// On both sides, but the local one is newer or a different size.
    case changed
    /// On both sides, but the backup's copy is the newer one. Never overwritten automatically.
    case conflict
    /// Only on the backup (offloaded earlier, or deleted locally).
    case backupOnly
}

public struct FileDiff: Sendable, Hashable {
    /// Path below the link's folders, e.g. `Shoot 12/raw/DSC_0001.ARW`.
    public var relativePath: String
    public var status: FileBackupStatus
    /// Logical size of the local file (of the backup's for `backupOnly`).
    public var bytes: Int64
    public var lastUsed: Date?
    public var modified: Date?
}

public enum EntryState: String, Codable, Sendable {
    case backedUp, partial, notBackedUp, offloaded, conflict
}

/// One top-level item of a linked folder — typically a shoot or a project — summed up.
public struct LinkEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var kind: FileKind
    public var localBytes: Int64 = 0
    public var localCount = 0
    public var backedUpBytes: Int64 = 0
    public var pendingBytes: Int64 = 0
    public var pendingCount = 0
    public var conflictCount = 0
    public var backupOnlyBytes: Int64 = 0
    public var backupOnlyCount = 0
    /// Newest open or change of anything local in it.
    public var lastUsed: Date?
    /// Newest change of anything local in it.
    public var lastModified: Date?
    /// The state comes from the last comparison, because the backup drive isn't connected now.
    public var remembered = false

    public var state: EntryState {
        if conflictCount > 0 { return .conflict }
        if localCount == 0 { return .offloaded }
        if pendingCount == 0 { return .backedUp }
        return backedUpBytes == 0 ? .notBackedUp : .partial
    }

    public func daysUntouched(now: Date = Date()) -> Int? {
        lastUsed.map { max(0, Int(now.timeIntervalSince($0) / 86400)) }
    }

    /// Fully on the backup and left alone long enough: its local copy can go.
    public func isOffloadCandidate(afterDays: Int, now: Date = Date()) -> Bool {
        state == .backedUp && localBytes > 0 && (daysUntouched(now: now) ?? 0) >= afterDays
    }
}

public struct LinkReport: Codable, Sendable {
    public var linkID: UUID
    public var scannedAt: Date
    public var sourceExists: Bool
    public var destinationConnected: Bool
    /// When the two sides were last actually compared (differs from `scannedAt` while the drive is away).
    public var comparedAt: Date?
    /// Biggest local first, then offloaded ones.
    public var entries: [LinkEntry]

    public var localBytes: Int64 { entries.reduce(0) { $0 + $1.localBytes } }
    public var backedUpBytes: Int64 { entries.reduce(0) { $0 + $1.backedUpBytes } }
    public var pendingBytes: Int64 { entries.reduce(0) { $0 + $1.pendingBytes } }
    public var pendingCount: Int { entries.reduce(0) { $0 + $1.pendingCount } }
    public var backupOnlyBytes: Int64 { entries.reduce(0) { $0 + $1.backupOnlyBytes } }
    public var conflictCount: Int { entries.reduce(0) { $0 + $1.conflictCount } }

    public func offloadCandidates(afterDays: Int, now: Date = Date()) -> [LinkEntry] {
        entries.filter { !$0.remembered && $0.isOffloadCandidate(afterDays: afterDays, now: now) }
    }
}

/// Links and the last comparison of each, as JSON next to the settings.
public final class LinkStore: Sendable {
    public let directory: URL

    public init(directory: URL = AppSupport.directory().appending(path: "links", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var listURL: URL { directory.appending(path: "links.json") }
    private func reportURL(_ id: UUID) -> URL { directory.appending(path: "report-\(id.uuidString).json") }

    public func load() -> [FolderLink] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? JSONDecoder().decode([FolderLink].self, from: data)) ?? []
    }

    public func save(_ links: [FolderLink]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(links).write(to: listURL, options: .atomic)
    }

    public func lastReport(_ id: UUID) -> LinkReport? {
        guard let data = try? Data(contentsOf: reportURL(id)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LinkReport.self, from: data)
    }

    public func remember(_ report: LinkReport) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(report).write(to: reportURL(report.linkID), options: .atomic)
    }

    public func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: reportURL(id))
    }
}

/// Compares the two sides of a link. Read-only.
public enum LinkScanner {
    /// Dates on exFAT/FAT drives are kept to two seconds.
    static let dateTolerance: TimeInterval = 2

    struct FileFact {
        var size: Int64
        var modified: Double
        var used: Double
    }

    static func isSkipped(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name.hasSuffix(LinkEngine.partialSuffix)
            || [".localized", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"].contains(name)
    }

    /// Every regular file below `root` (optionally only below its top-level item `entry`), keyed by relative path.
    /// Symlinks are neither followed nor listed.
    static func walk(_ root: String, entry: String? = nil, cancel: CancellationFlag) -> [String: FileFact] {
        var out: [String: FileFact] = [:]
        func visit(_ path: String, _ rel: String) {
            if cancel.isCancelled { return }
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                for name in DiskSizer.listDirectory(path) where !isSkipped(name) {
                    visit(path + "/" + name, rel.isEmpty ? name : rel + "/" + name)
                }
            case S_IFREG:
                guard !rel.isEmpty else { return }
                let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                let a = Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9
                out[rel] = FileFact(size: Int64(st.st_size), modified: m, used: max(m, a))
            default:
                return
            }
        }
        if let entry {
            visit(root + "/" + entry, entry)
        } else {
            visit(root, "")
        }
        return out
    }

    /// File-by-file comparison, sorted by path. `entry` limits it to one top-level item.
    public static func diff(_ link: FolderLink, entry: String? = nil,
                            cancel: CancellationFlag = CancellationFlag()) -> [FileDiff] {
        let local = walk(link.source.trimmingSuffix("/"), entry: entry, cancel: cancel)
        let remote = link.destinationConnected
            ? walk(link.destination.trimmingSuffix("/"), entry: entry, cancel: cancel) : [:]
        var out: [FileDiff] = []
        out.reserveCapacity(local.count)
        for (rel, l) in local {
            let status: FileBackupStatus
            if let r = remote[rel] {
                let sameDate = abs(l.modified - r.modified) <= dateTolerance
                if l.size == r.size && sameDate {
                    status = .backedUp
                } else if r.modified > l.modified + dateTolerance {
                    status = .conflict
                } else {
                    status = .changed
                }
            } else {
                status = .missing
            }
            out.append(FileDiff(relativePath: rel, status: status, bytes: l.size,
                                lastUsed: Date(timeIntervalSince1970: l.used),
                                modified: Date(timeIntervalSince1970: l.modified)))
        }
        for (rel, r) in remote where local[rel] == nil {
            out.append(FileDiff(relativePath: rel, status: .backupOnly, bytes: r.size, lastUsed: nil,
                                modified: Date(timeIntervalSince1970: r.modified)))
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// Sums the comparison up per top-level item. With the backup drive away, states are carried over from
    /// `previous` for items that haven't changed locally since, and marked `remembered`.
    public static func report(_ link: FolderLink, previous: LinkReport? = nil,
                              cancel: CancellationFlag = CancellationFlag()) -> LinkReport {
        let connected = link.destinationConnected
        let sourceExists = FS.isDirectory(link.sourceURL)
        var byName: [String: LinkEntry] = [:]
        var kindBytes: [String: [Int64]] = [:]
        let source = link.source.trimmingSuffix("/")
        for file in diff(link, cancel: cancel) {
            let top = file.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? file.relativePath
            let isDirectory = file.relativePath.contains("/")
            var e = byName[top] ?? LinkEntry(name: top, isDirectory: isDirectory, kind: .other)
            if isDirectory { e.isDirectory = true }
            switch file.status {
            case .backupOnly:
                e.backupOnlyBytes += file.bytes
                e.backupOnlyCount += 1
            case .backedUp, .missing, .changed, .conflict:
                e.localBytes += file.bytes
                e.localCount += 1
                if let d = file.lastUsed { e.lastUsed = max(e.lastUsed ?? d, d) }
                if let d = file.modified { e.lastModified = max(e.lastModified ?? d, d) }
                let name = String(file.relativePath.split(separator: "/").last ?? "")
                kindBytes[top, default: Array(repeating: 0, count: FileKind.allCases.count)][FileClassifier.kind(ofFile: name).rawValue] += file.bytes
                switch file.status {
                case .backedUp: e.backedUpBytes += file.bytes
                case .conflict: e.conflictCount += 1
                default:
                    e.pendingBytes += file.bytes
                    e.pendingCount += 1
                }
            }
            byName[top] = e
        }
        var entries: [LinkEntry] = byName.values.map { entry in
            var e = entry
            if let kb = kindBytes[e.name], let top = kb.indices.max(by: { kb[$0] < kb[$1] }), kb[top] > 0 {
                e.kind = FileKind(rawValue: top) ?? .other
            }
            return e
        }
        var comparedAt: Date? = connected ? Date() : nil
        if !connected, let previous, let then = previous.comparedAt {
            comparedAt = then
            let old = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.name, $0) })
            entries = entries.map { entry in
                var e = entry
                guard let was = old[e.name], was.state == .backedUp, was.localBytes == e.localBytes,
                      was.localCount == e.localCount, (e.lastModified ?? .distantPast) <= then else { return e }
                e.backedUpBytes = e.localBytes
                e.pendingBytes = 0
                e.pendingCount = 0
                e.remembered = true
                return e
            }
            // Things that were only on the backup are still worth showing while the drive is away.
            for was in previous.entries where was.localCount == 0 && byName[was.name] == nil
                && !FS.exists(URL(filePath: source + "/" + was.name)) {
                var e = was
                e.remembered = true
                entries.append(e)
            }
        }
        entries.sort { a, b in
            a.localBytes != b.localBytes ? a.localBytes > b.localBytes : a.backupOnlyBytes > b.backupOnlyBytes
        }
        return LinkReport(linkID: link.id, scannedAt: Date(), sourceExists: sourceExists,
                          destinationConnected: connected, comparedAt: comparedAt, entries: entries)
    }
}
