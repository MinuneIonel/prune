import Darwin
import Foundation
import Synchronization

/// Remembers which hard-linked inodes have already been counted during one scan,
/// so pnpm-style hard-link farms are only counted once.
public final class InodeTracker: Sendable {
    private struct Key: Hashable { let dev: Int32; let ino: UInt64 }
    private let seen = Mutex<Set<Key>>([])

    public init() {}

    /// Returns true the first time an inode is seen.
    func claim(dev: Int32, ino: UInt64) -> Bool {
        seen.withLock { $0.insert(Key(dev: dev, ino: ino)).inserted }
    }

    public var count: Int { seen.withLock { $0.count } }
}

/// Cooperative cancellation flag that blocking file-system walks can poll.
public final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

public struct SizeResult: Sendable, Equatable {
    public var allocatedBytes: Int64
    public var lastUsed: Date?
    public var fileCount: Int
}

/// Computes allocated size on disk. Doesn't follow symlinks, doesn't cross volume boundaries,
/// counts each hard-linked inode once per `InodeTracker`.
public enum DiskSizer {
    /// Async wrapper: runs the blocking walk off the cooperative pool and wires up task cancellation.
    public static func size(of url: URL, tracker: InodeTracker) async -> SizeResult? {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<SizeResult?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: sizeSync(of: url, tracker: tracker, cancel: flag))
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Blocking walk. Returns nil if the path doesn't exist.
    public static func sizeSync(of url: URL, tracker: InodeTracker, cancel: CancellationFlag = CancellationFlag()) -> SizeResult? {
        let rootPath = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { return nil }
        let rootDev = st.st_dev
        var total = Int64(0)
        var count = 0
        var newest = entryDate(st)
        total += counted(st, tracker: tracker)
        count += 1

        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            return SizeResult(allocatedBytes: total, lastUsed: newest, fileCount: count)
        }

        // Breadth-first expansion of the top few levels so large trees are walked in parallel.
        var frontier: [String] = []
        var level: [String] = [rootPath]
        var depth = 0
        while !level.isEmpty {
            var next: [String] = []
            for dir in level {
                if cancel.isCancelled { return nil }
                for name in listDirectory(dir) {
                    let child = dir.hasSuffix("/") ? dir + name : dir + "/" + name
                    var cst = stat()
                    guard lstat(child, &cst) == 0 else { continue }
                    if depth == 0, let d = entryDate(cst) { newest = max(newest ?? d, d) }
                    if (cst.st_mode & S_IFMT) == S_IFDIR {
                        if cst.st_dev != rootDev { continue }  // mount point: don't cross
                        total += counted(cst, tracker: tracker)
                        count += 1
                        next.append(child)
                    } else {
                        total += counted(cst, tracker: tracker)
                        count += 1
                    }
                }
            }
            depth += 1
            if next.count >= 48 || depth >= 3 {
                frontier = next
                break
            }
            level = next
        }

        if !frontier.isEmpty {
            let partials = Mutex<(Int64, Int)>((0, 0))
            let dirs = frontier
            DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                // Each frontier dir has already been counted itself; walk its contents.
                let (b, c) = walk(dirs[i], rootDev: rootDev, tracker: tracker, cancel: cancel)
                partials.withLock { $0.0 += b; $0.1 += c }
            }
            let (b, c) = partials.withLock { $0 }
            total += b
            count += c
        }
        if cancel.isCancelled { return nil }
        return SizeResult(allocatedBytes: total, lastUsed: newest, fileCount: count)
    }

    /// Size of everything *below* `dir` (not `dir` itself) using fts.
    private static func walk(_ dir: String, rootDev: dev_t, tracker: InodeTracker, cancel: CancellationFlag) -> (Int64, Int) {
        var total = Int64(0)
        var count = 0
        let cPath = strdup(dir)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return (0, 0) }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            if count & 0x3FF == 0, cancel.isCancelled { break }
            let info = Int32(ent.pointee.fts_info)
            if ent.pointee.fts_level == 0 { continue }  // root already counted by caller
            switch info {
            case FTS_DP, FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK, FTS_DC:
                continue
            default:
                guard let sp = ent.pointee.fts_statp else { continue }
                if sp.pointee.st_dev != rootDev { fts_set(fts, ent, FTS_SKIP); continue }
                total += counted(sp.pointee, tracker: tracker)
                count += 1
            }
        }
        return (total, count)
    }

    private static func counted(_ st: stat, tracker: InodeTracker) -> Int64 {
        let bytes = Int64(st.st_blocks) * 512
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if !isDir && st.st_nlink > 1 {
            return tracker.claim(dev: st.st_dev, ino: st.st_ino) ? bytes : 0
        }
        return bytes
    }

    /// Directories: modification date only (listing a directory can bump its atime, including our own scans).
    /// Files: newest of modification and access date.
    static func entryDate(_ st: stat) -> Date? {
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if (st.st_mode & S_IFMT) == S_IFDIR { return Date(timeIntervalSince1970: m) }
        let a = Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9
        return Date(timeIntervalSince1970: max(m, a))
    }

    static func listDirectory(_ path: String) -> [String] {
        guard let d = opendir(path) else { return [] }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// "Last used" for an item without sizing it (top level only).
    public static func lastUsed(of url: URL) -> Date? {
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var newest = entryDate(st)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            for name in listDirectory(path) {
                var cst = stat()
                if lstat(path + "/" + name, &cst) == 0, let d = entryDate(cst) { newest = max(newest ?? d, d) }
            }
        }
        return newest
    }
}
