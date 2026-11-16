import CryptoKit
import Darwin
import Foundation

public struct LinkError: Error, Sendable, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

public struct LinkProgress: Sendable, Equatable {
    public var doneBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var doneFiles = 0
    public var totalFiles = 0
    public var current = ""

    public init(doneBytes: Int64 = 0, totalBytes: Int64 = 0, doneFiles: Int = 0, totalFiles: Int = 0, current: String = "") {
        self.doneBytes = doneBytes
        self.totalBytes = totalBytes
        self.doneFiles = doneFiles
        self.totalFiles = totalFiles
        self.current = current
    }
}

public struct LinkOutcome: Sendable, Identifiable, Equatable {
    public var id: String { name }
    /// Top-level item of the link.
    public var name: String
    public var files = 0
    public var bytes: Int64 = 0
    /// Why nothing was done for this item (it wasn't safe, or wasn't needed).
    public var skipped: String?
    public var error: String?

    public var succeeded: Bool { skipped == nil && error == nil }
}

public struct LinkRunReport: Sendable, Equatable {
    public enum Action: String, Sendable { case backUp, offload, bringBack }
    public var action: Action
    /// False for a dry run: `outcomes` then say what would happen.
    public var executed: Bool
    public var outcomes: [LinkOutcome]
    public var cancelled = false

    public var bytes: Int64 { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.bytes } }
    public var files: Int { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.files } }
    public var problems: [LinkOutcome] { outcomes.filter { !$0.succeeded } }
}

/// Acts on a link: copies to the backup, frees local copies that are verified to be on the backup, and brings
/// offloaded things back. Every method is a dry run unless `execute` is true.
///
/// The rules it never breaks: nothing on the backup is ever deleted; a newer file on the backup is never
/// overwritten; a local item only leaves (to the Trash, never deleted) after every file in it has been compared
/// with its copy by size, date and content right before.
public struct LinkEngine: Sendable {
    static let partialSuffix = ".nspart"
    /// Files up to this size are compared by a hash of everything; bigger ones by size, date and a hash of
    /// their first and last 4 MiB, unless `thorough`.
    static let fullHashLimit: Int64 = 16 << 20

    public var link: FolderLink
    public var home: URL
    public var remover: any FileRemover
    public var history: HistoryLog?
    /// Hash every byte of every file on both sides before offloading (slow on big shoots).
    public var thorough: Bool
    public var cancel: CancellationFlag

    public init(link: FolderLink, home: URL, remover: any FileRemover, history: HistoryLog? = nil,
                thorough: Bool = false, cancel: CancellationFlag = CancellationFlag()) {
        self.link = link
        self.home = home.standardizedFileURL
        self.remover = remover
        self.history = history
        self.thorough = thorough
        self.cancel = cancel
    }

    private var source: String { link.source.trimmingSuffix("/") }
    private var destination: String { link.destination.trimmingSuffix("/") }

    private func top(_ relativePath: String) -> String {
        relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relativePath
    }

    private func checkReady() throws {
        guard FS.isDirectory(link.sourceURL) else { throw LinkError("The folder \(link.source) isn't there.") }
        guard link.destinationConnected else { throw LinkError("The backup drive isn't connected.") }
        let s = URL(filePath: source).resolvingSymlinksInPath().path, d = URL(filePath: destination).resolvingSymlinksInPath().path
        if s == d || s.hasPrefix(d + "/") || d.hasPrefix(s + "/") {
            throw LinkError("The folder and its backup can't be inside each other.")
        }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !LinkScanner.isSkipped(name)
    }

    // MARK: Back up

    /// Copies everything that is missing from the backup or newer locally. `entries` nil = the whole link.
    public func backUp(entries: [String]? = nil, execute: Bool,
                       progress: @Sendable (LinkProgress) -> Void = { _ in }) -> LinkRunReport {
        copy(.backUp, entries: entries, execute: execute, progress: progress)
    }

    /// Copies offloaded items (only on the backup) back into the local folder.
    public func bringBack(entries: [String], execute: Bool,
                          progress: @Sendable (LinkProgress) -> Void = { _ in }) -> LinkRunReport {
        copy(.bringBack, entries: entries, execute: execute, progress: progress)
    }

    private func copy(_ action: LinkRunReport.Action, entries: [String]?, execute: Bool,
                      progress: @Sendable (LinkProgress) -> Void) -> LinkRunReport {
        do { try checkReady() } catch {
            return LinkRunReport(action: action, executed: execute,
                                 outcomes: [LinkOutcome(name: link.name, error: String(describing: error))])
        }
        let wanted: Set<FileBackupStatus> = action == .backUp ? [.missing, .changed] : [.backupOnly]
        var diffs: [FileDiff] = []
        if let entries {
            for name in entries where validName(name) { diffs += LinkScanner.diff(link, entry: name, cancel: cancel) }
        } else {
            diffs = LinkScanner.diff(link, cancel: cancel)
        }
        let todo = diffs.filter { wanted.contains($0.status) }
        var state = LinkProgress(totalBytes: todo.reduce(0) { $0 + $1.bytes }, totalFiles: todo.count)
        var outcomes: [String: LinkOutcome] = [:]
        var order: [String] = []
        let (from, to) = action == .backUp ? (source, destination) : (destination, source)
        for file in todo {
            if cancel.isCancelled { break }
            let name = top(file.relativePath)
            if outcomes[name] == nil { outcomes[name] = LinkOutcome(name: name); order.append(name) }
            guard outcomes[name]?.error == nil else { continue }
            state.current = file.relativePath
            progress(state)
            if execute {
                do {
                    let base = state.doneBytes
                    try LinkIO.copyVerified(from: from + "/" + file.relativePath, to: to + "/" + file.relativePath,
                                            replaceExisting: action == .backUp, cancel: cancel) { written in
                        var s = state
                        s.doneBytes = base + written
                        progress(s)
                    }
                } catch {
                    outcomes[name]?.error = "\(file.relativePath): \(error)"
                    continue
                }
            }
            outcomes[name]?.files += 1
            outcomes[name]?.bytes += file.bytes
            state.doneBytes += file.bytes
            state.doneFiles += 1
            progress(state)
        }
        return LinkRunReport(action: action, executed: execute, outcomes: order.compactMap { outcomes[$0] },
                             cancelled: cancel.isCancelled)
    }

    // MARK: Offload

    /// Folders that must never be moved to the Trash as a whole, whatever is linked.
    private var protectedPaths: Set<String> {
        let h = home.path(percentEncoded: false).trimmingSuffix("/")
        var out: Set<String> = [h, "/", "/Users", "/Volumes", "/Applications", "/Library", "/System"]
        for name in ["Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            out.insert(h + "/" + name)
        }
        return out
    }

    /// Frees the local copy of each named top-level item, if and only if every file in it is on the backup:
    /// each one is compared with its copy (size, date, content) right now, then the item goes to the Trash.
    public func offload(entries: [String], execute: Bool,
                        progress: @Sendable (LinkProgress) -> Void = { _ in }) -> LinkRunReport {
        do { try checkReady() } catch {
            return LinkRunReport(action: .offload, executed: execute,
                                 outcomes: [LinkOutcome(name: link.name, error: String(describing: error))])
        }
        var plans: [(name: String, files: [FileDiff], outcome: LinkOutcome)] = []
        for name in entries {
            var outcome = LinkOutcome(name: name)
            let path = source + "/" + name
            var files: [FileDiff] = []
            if !validName(name) {
                outcome.error = "Not an item of this folder."
            } else if protectedPaths.contains(path)
                        || URL(filePath: path).resolvingSymlinksInPath().deletingLastPathComponent().path
                            != URL(filePath: source).resolvingSymlinksInPath().path {
                outcome.error = "This location is protected and is never moved to the Trash."
            } else {
                files = LinkScanner.diff(link, entry: name, cancel: cancel).filter { $0.status != .backupOnly }
                let unsafe = files.filter { $0.status != .backedUp }
                if files.isEmpty {
                    outcome.skipped = "Nothing local to free."
                } else if !unsafe.isEmpty {
                    outcome.skipped = "\(unsafe.count) file\(unsafe.count == 1 ? " isn't" : "s aren't") on the backup yet. Back up first."
                    files = []
                }
            }
            plans.append((name, files, outcome))
        }
        var state = LinkProgress(totalBytes: plans.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.bytes } },
                                 totalFiles: plans.reduce(0) { $0 + $1.files.count })
        var outcomes: [LinkOutcome] = []
        for plan in plans {
            var outcome = plan.outcome
            defer { outcomes.append(outcome) }
            guard outcome.succeeded, !plan.files.isEmpty else { continue }
            if cancel.isCancelled { outcome.skipped = "Cancelled."; continue }
            for file in plan.files {
                if cancel.isCancelled { outcome.skipped = "Cancelled."; break }
                state.current = file.relativePath
                progress(state)
                do {
                    try LinkIO.verifySame(source + "/" + file.relativePath, destination + "/" + file.relativePath,
                                          thorough: thorough)
                } catch {
                    outcome.error = "\(file.relativePath): \(error)"
                    break
                }
                state.doneBytes += file.bytes
                state.doneFiles += 1
            }
            guard outcome.succeeded else { continue }
            outcome.files = plan.files.count
            outcome.bytes = plan.files.reduce(0) { $0 + $1.bytes }
            if execute {
                do {
                    try remover.trash(URL(filePath: source + "/" + plan.name))
                } catch {
                    outcome.error = "Couldn't move it to the Trash: \(error.localizedDescription)"
                }
            }
            progress(state)
        }
        let report = LinkRunReport(action: .offload, executed: execute, outcomes: outcomes, cancelled: cancel.isCancelled)
        if execute, report.files > 0 { record(report) }
        return report
    }

    private func record(_ report: LinkRunReport) {
        let items = report.outcomes.map {
            HistoryEntry.ItemRecord(ruleID: "link-offload", itemID: $0.name, displayName: "\(link.name) › \($0.name)",
                                    path: source + "/" + $0.name, method: "move to Trash (verified on backup)",
                                    estimatedBytes: $0.bytes, succeeded: $0.succeeded, error: $0.error ?? $0.skipped)
        }
        // The space comes back when the Trash is emptied, so nothing has been reclaimed yet.
        try? history?.append(HistoryEntry(id: UUID(), date: Date(), ruleIDs: ["link-offload"], items: items,
                                          estimatedBytes: report.bytes, reclaimedBytes: 0))
    }
}

/// File copying and comparing for links.
enum LinkIO {
    static let chunk = 4 << 20

    private static func open(_ path: String, _ flags: Int32, noCache: Bool = false) throws -> Int32 {
        let fd = Darwin.open(path, flags, 0o644)
        guard fd >= 0 else { throw LinkError("can't open (\(String(cString: strerror(errno))))") }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        return fd
    }

    private static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer, at offset: Int64? = nil) throws -> Int {
        var total = 0
        while total < buffer.count {
            let n: Int
            if let offset {
                n = pread(fd, buffer.baseAddress! + total, buffer.count - total, offset + Int64(total))
            } else {
                n = read(fd, buffer.baseAddress! + total, buffer.count - total)
            }
            if n < 0 { if errno == EINTR { continue }; throw LinkError("read failed (\(String(cString: strerror(errno))))") }
            if n == 0 { break }
            total += n
        }
        return total
    }

    /// SHA-256 of the whole file, or of its first and last 4 MiB plus its length.
    static func fingerprint(_ path: String, full: Bool, noCache: Bool = false) throws -> String {
        let fd = try open(path, O_RDONLY | O_NOFOLLOW, noCache: noCache)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw LinkError("can't stat") }
        let size = Int64(st.st_size)
        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        if full || size <= Int64(chunk) * 2 {
            while true {
                let n = try readFully(fd, buffer)
                if n == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            }
        } else {
            for offset in [0, size - Int64(chunk)] {
                let n = try readFully(fd, buffer, at: offset)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            }
            withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func facts(_ path: String) throws -> (size: Int64, modified: Double, st: stat) {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw LinkError("isn't there any more") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw LinkError("isn't a regular file") }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, st)
    }

    /// Throws unless `a` and `b` are the same size, the same date and have the same content.
    static func verifySame(_ a: String, _ b: String, thorough: Bool) throws {
        let fa = try facts(a)
        let fb: (size: Int64, modified: Double, st: stat)
        do { fb = try facts(b) } catch { throw LinkError("the backup copy \(error)") }
        guard fa.size == fb.size else { throw LinkError("the backup copy is a different size") }
        guard abs(fa.modified - fb.modified) <= LinkScanner.dateTolerance else {
            throw LinkError("the backup copy has a different date")
        }
        let full = thorough || fa.size <= LinkEngine.fullHashLimit
        guard try fingerprint(a, full: full) == fingerprint(b, full: full, noCache: true) else {
            throw LinkError("the backup copy's content differs")
        }
    }

    /// Copies `from` to `to` through a temporary file next to the target, reads the copy back from the drive and
    /// compares it with what was read from the original, gives it the original's date, then renames it into place.
    static func copyVerified(from: String, to: String, replaceExisting: Bool, cancel: CancellationFlag,
                             written: (Int64) -> Void) throws {
        let before = try facts(from)
        let target = URL(filePath: to)
        if !replaceExisting, FS.exists(target) { throw LinkError("something is already there") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().path(percentEncoded: false)
            + "." + target.lastPathComponent + LinkEngine.partialSuffix
        var finished = false
        defer { if !finished { unlink(temp) } }

        let input = try open(from, O_RDONLY | O_NOFOLLOW)
        defer { close(input) }
        let output = try open(temp, O_WRONLY | O_CREAT | O_TRUNC)
        var outputOpen = true
        defer { if outputOpen { close(output) } }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var total = Int64(0)
        while true {
            if cancel.isCancelled { throw LinkError("cancelled") }
            let n = try readFully(input, buffer)
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            var off = 0
            while off < n {
                let w = write(output, buffer.baseAddress! + off, n - off)
                if w < 0 { if errno == EINTR { continue }; throw LinkError("write failed (\(String(cString: strerror(errno))))") }
                off += w
            }
            total += Int64(n)
            written(total)
        }
        guard fsync(output) == 0 else { throw LinkError("couldn't flush to the drive") }
        // Same date as the original, so the two sides compare equal from now on.
        var times = [before.st.st_atimespec, before.st.st_mtimespec]
        guard futimens(output, &times) == 0 else { throw LinkError("couldn't set the copy's date") }
        _ = fchmod(output, before.st.st_mode & 0o777)
        close(output)
        outputOpen = false

        let sourceHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == before.size, try facts(from).modified == before.modified else {
            throw LinkError("changed while it was being copied")
        }
        guard try fingerprint(temp, full: true, noCache: true) == sourceHash else {
            throw LinkError("the copy read back differently from the original")
        }
        guard rename(temp, to) == 0 else { throw LinkError("couldn't put the copy in place (\(String(cString: strerror(errno))))") }
        finished = true
    }
}
