import CryptoKit
import Darwin
import Foundation

// Low-level I/O for NAS offload: a buffered, hashing writer and reader over raw file descriptors with the
// page cache switched off (F_NOCACHE), extended attributes, and a source-tree walker that records exactly
// what will be archived. Everything here is synchronous; the engine calls it from a background task.

let ioChunk = 4 * 1024 * 1024
/// Files over the checksum cap are verified by size plus a hash of their first and last 4 MiB.
let sampleBytes: Int64 = 4 * 1024 * 1024

extension SHA256Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func posixError(_ what: String, _ path: String, _ code: Int32 = errno) -> OffloadError {
    .io("\(what) \(path): \(String(cString: strerror(code)))")
}

/// Streams bytes to a new file (never overwrites: O_EXCL), hashing everything written.
/// `checkpoint` runs after every flushed chunk with the total written so far; throwing from it aborts the copy
/// (cancellation, share gone, injected failure).
final class PayloadSink {
    let path: String
    private let fd: Int32
    private var hasher = SHA256()
    private(set) var written: Int64 = 0
    private var buffer: [UInt8] = []
    private let checkpoint: (Int64) throws -> Void
    private var closed = false

    init(path: String, checkpoint: @escaping (Int64) throws -> Void) throws {
        self.path = path
        self.checkpoint = checkpoint
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw posixError("can't create", path) }
        _ = fcntl(fd, F_NOCACHE, 1)
        buffer.reserveCapacity(Self.coalesce + ioChunk)
    }

    deinit { if !closed { close(fd) } }

    /// Writes are coalesced into ≥ 1 MiB requests: with the cache off every write is a round trip to the server,
    /// so thousands of small files' headers and contents must not each become their own SMB write.
    static let coalesce = 1024 * 1024

    func append(_ bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes)
        if buffer.count >= Self.coalesce { try flush() }
    }

    func append(_ data: Data) throws { try append([UInt8](data)) }

    /// Small chunks join the buffer; large ones go straight through (after it).
    func write(_ chunk: UnsafeRawBufferPointer) throws {
        if chunk.count < Self.coalesce {
            buffer.append(contentsOf: chunk)
            if buffer.count >= Self.coalesce { try flush() }
            return
        }
        try flush()
        try writeAll(chunk)
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        let b = buffer
        buffer.removeAll(keepingCapacity: true)
        try b.withUnsafeBytes { try writeAll($0) }
    }

    private func writeAll(_ chunk: UnsafeRawBufferPointer) throws {
        guard chunk.count > 0, let base = chunk.baseAddress else { return }
        var off = 0
        while off < chunk.count {
            let n = Darwin.write(fd, base + off, chunk.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError("write failed on", path)
            }
            off += n
        }
        hasher.update(bufferPointer: chunk)
        written += Int64(chunk.count)
        try checkpoint(written)
    }

    /// Flushes, syncs to the server and closes. Returns the SHA-256 of everything written.
    func finish() throws -> String {
        try flush()
        // F_FULLFSYNC isn't supported by every file system (smbfs may refuse it); fsync is the fallback.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw posixError("can't sync", path) }
        closed = true
        guard close(fd) == 0 else { throw posixError("can't close", path) }
        return hasher.finalize().hex
    }

    func abort() {
        guard !closed else { return }
        closed = true
        close(fd)
    }
}

/// Buffered reader over a file, hashing what it consumes (until a skip makes the whole-file hash impossible).
final class PayloadSource {
    let path: String
    private let fd: Int32
    private var hasher = SHA256()
    private(set) var hashesEverything = true
    private(set) var offset: Int64 = 0
    private let buffer: UnsafeMutableRawBufferPointer
    private var start = 0
    private var end = 0
    private let checkpoint: (Int64) throws -> Void
    /// Bytes actually read from disk / the network (skips don't count).
    private(set) var transferred: Int64 = 0

    init(path: String, checkpoint: @escaping (Int64) throws -> Void = { _ in }) throws {
        self.path = path
        self.checkpoint = checkpoint
        fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("can't open", path) }
        // Read from the server, not from what this Mac still has cached from writing it.
        _ = fcntl(fd, F_NOCACHE, 1)
        buffer = .allocate(byteCount: ioChunk, alignment: 16)
    }

    deinit {
        close(fd)
        buffer.deallocate()
    }

    private func fill() throws -> Bool {
        start = 0
        end = 0
        while true {
            let n = Darwin.read(fd, buffer.baseAddress!, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError("read failed on", path)
            }
            end = n
            transferred += Int64(n)
            if n > 0 { try checkpoint(transferred) }
            return n > 0
        }
    }

    /// Consumes exactly `count` bytes, handing them over in chunks.
    func read(_ count: Int64, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            if start == end, try !fill() { throw OffloadError.verification("\(path) ends early (truncated copy)") }
            let n = Int(min(Int64(end - start), remaining))
            let slice = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[start..<(start + n)])
            if hashesEverything { hasher.update(bufferPointer: slice) }
            try body(slice)
            start += n
            remaining -= Int64(n)
            offset += Int64(n)
        }
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        try read(Int64(count)) { out.append(contentsOf: $0) }
        return out
    }

    /// Skips bytes without reading them over the network when the range is outside the buffer.
    func skip(_ count: Int64) throws {
        guard count > 0 else { return }
        let buffered = Int64(end - start)
        if count <= buffered {
            try read(count) { _ in }
            return
        }
        hashesEverything = false
        let target = offset + count
        start = 0
        end = 0
        guard lseek(fd, off_t(target), SEEK_SET) == off_t(target) else { throw posixError("can't seek in", path) }
        offset = target
    }

    /// True when nothing is left.
    func atEnd() throws -> Bool { start == end ? try !fill() : false }

    var sha256: String? { hashesEverything ? hasher.finalize().hex : nil }
}

// MARK: Extended attributes

enum XAttr {
    /// Kernel-managed attributes that can't be written back, so they're neither archived nor verified.
    static let excluded: Set<String> = ["com.apple.provenance"]

    static func read(_ path: String) -> [(name: String, value: Data)] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        let n = listxattr(path, &names, size, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        var out: [(String, Data)] = []
        for raw in names[0..<n].split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !excluded.contains(name) else { continue }
            let vs = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard vs >= 0 else { continue }
            var value = Data(count: vs)
            let got = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, vs, 0, XATTR_NOFOLLOW) }
            guard got >= 0 else { continue }
            out.append((name, value.prefix(got)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Order-independent digest of names and values (nil when there are none).
    static func digest(_ attrs: [(name: String, value: Data)]) -> String? {
        guard !attrs.isEmpty else { return nil }
        var h = SHA256()
        for (name, value) in attrs.sorted(by: { $0.name < $1.name }) {
            h.update(data: Data(name.utf8))
            h.update(data: Data([0]))
            var len = UInt64(value.count).littleEndian
            withUnsafeBytes(of: &len) { h.update(bufferPointer: $0) }
            h.update(data: value)
        }
        return h.finalize().hex
    }

    /// Returns how many attributes couldn't be set.
    @discardableResult
    static func write(_ attrs: [(name: String, value: Data)], to path: String) -> Int {
        var failed = 0
        for (name, value) in attrs {
            let r = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            if r != 0 { failed += 1 }
        }
        return failed
    }
}

// MARK: Source tree

/// One thing inside the item being offloaded, as `lstat` saw it before copying.
struct SourceNode: Sendable, Equatable {
    var rel: String
    var type: OffloadEntry.Kind
    var size: Int64
    var mode: UInt16
    var modified: Date
    var linkTarget: String?
}

enum SourceTree {
    /// Everything under `root` (root first, parents before children, names sorted), without following symlinks or
    /// crossing into another volume. Sockets, FIFOs and devices can't be archived meaningfully; they're returned in
    /// `skipped` (git's fsmonitor socket is the usual one).
    static func walk(_ root: URL) throws -> (nodes: [SourceNode], skipped: [String]) {
        let rootPath = root.path(percentEncoded: false)
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw posixError("can't read", rootPath) }
        let rootDev = st.st_dev
        var nodes: [SourceNode] = []
        var skipped: [String] = []

        func node(_ rel: String, _ path: String, _ st: stat) throws -> SourceNode? {
            let fmt = st.st_mode & S_IFMT
            let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
            let mode = UInt16(st.st_mode & 0o7777)
            switch fmt {
            case S_IFREG: return SourceNode(rel: rel, type: .file, size: Int64(st.st_size), mode: mode, modified: modified)
            case S_IFDIR: return SourceNode(rel: rel, type: .directory, size: 0, mode: mode, modified: modified)
            case S_IFLNK:
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(path, &buf, Int(PATH_MAX))
                guard n >= 0 else { throw posixError("can't read link", path) }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return SourceNode(rel: rel, type: .symlink, size: 0, mode: mode, modified: modified, linkTarget: target)
            default:
                skipped.append(rel.isEmpty ? "." : rel)
                return nil
            }
        }

        guard let first = try node("", rootPath, st) else {
            throw OffloadError.refused("\(rootPath) is not a file, folder or link")
        }
        if first.type == .symlink { throw OffloadError.refused("\(rootPath) is a symbolic link; offload what it points to instead") }
        nodes.append(first)
        guard first.type == .directory else { return (nodes, skipped) }

        var stack: [(rel: String, path: String)] = [("", rootPath)]
        while let (rel, path) = stack.popLast() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            } catch {
                throw OffloadError.io("can't list \(path): \(error.localizedDescription)")
            }
            var subdirs: [(String, String)] = []
            for name in names {
                let childRel = rel.isEmpty ? name : rel + "/" + name
                let childPath = path + "/" + name
                var cst = stat()
                guard lstat(childPath, &cst) == 0 else { throw posixError("can't read", childPath) }
                if (cst.st_mode & S_IFMT) == S_IFDIR, cst.st_dev != rootDev {
                    skipped.append(childRel + " (another volume mounted here)")
                    continue
                }
                guard let n = try node(childRel, childPath, cst) else { continue }
                nodes.append(n)
                if n.type == .directory { subdirs.append((childRel, childPath)) }
            }
            // Depth-first in name order: push in reverse so the first name is handled next.
            for d in subdirs.reversed() { stack.append(d) }
        }
        // The stack visits a directory's subtree right after its own listing, so parents always precede children,
        // but files of a directory come before its subdirectories' contents. That order is fine for tar.
        return (nodes, skipped)
    }

    /// What changed between two walks (empty = unchanged). Compares type, size, modification date and link target.
    static func differences(_ a: [SourceNode], _ b: [SourceNode], limit: Int = 5) -> [String] {
        let old = Dictionary(a.map { ($0.rel, $0) }, uniquingKeysWith: { x, _ in x })
        let new = Dictionary(b.map { ($0.rel, $0) }, uniquingKeysWith: { x, _ in x })
        var out: [String] = []
        for rel in Set(old.keys).union(new.keys).sorted() {
            let name = rel.isEmpty ? "(the item itself)" : rel
            switch (old[rel], new[rel]) {
            case (nil, _?): out.append("added: \(name)")
            case (_?, nil): out.append("removed: \(name)")
            case let (x?, y?):
                // Directory dates change when anything inside is touched; contents are compared individually.
                if x.type != y.type || x.size != y.size || x.linkTarget != y.linkTarget
                    || (x.type != .directory && abs(x.modified.timeIntervalSince(y.modified)) > 0.000_5) {
                    out.append("changed: \(name)")
                }
            default: break
            }
            if out.count >= limit { break }
        }
        return out
    }
}
