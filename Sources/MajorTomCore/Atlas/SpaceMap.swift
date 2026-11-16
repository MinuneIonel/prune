import Darwin
import Foundation
import Synchronization

/// One folder or file on the space map. Items smaller than the scan's keep size are folded into
/// `smallBytes` of their folder so a home folder with millions of files stays light.
public struct MapNode: Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    /// Allocated bytes on disk, hard links counted once.
    public let size: Int64
    public let isDirectory: Bool
    /// A file's kind; for a folder, the kind that takes the most space inside it.
    public let kind: FileKind
    public let origin: Origin?
    /// Newest change or open of anything inside.
    public let lastUsed: Date?
    /// Biggest first.
    public let children: [MapNode]
    public let smallBytes: Int64
    public let smallCount: Int
    /// Bytes per `FileKind.rawValue` for folders; empty for files.
    public let kindBytes: [Int64]

    public func bytes(of kind: FileKind) -> Int64 {
        isDirectory ? kindBytes[kind.rawValue] : (kind == self.kind ? size : 0)
    }
}

public struct OriginTotal: Sendable, Identifiable {
    public var id: String { origin.id }
    public let origin: Origin
    public let bytes: Int64
    public let fileCount: Int
    /// A few of the biggest files, for "show me".
    public let largest: [(path: String, bytes: Int64)]
}

public struct SpaceMap: Sendable {
    public let root: MapNode
    /// Biggest first.
    public let origins: [OriginTotal]
    public let fileCount: Int
    public let unreadableFolders: Int
    public let scannedAt: Date
    public let duration: TimeInterval

    /// The node at `path`, if it was big enough to keep.
    public func node(at path: String) -> MapNode? {
        guard path.hasPrefix(root.path) else { return nil }
        var node = root
        while node.path != path {
            guard let next = node.children.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
                return nil
            }
            node = next
        }
        return node
    }
}

/// Walks a folder once and builds the space map: sizes, kinds, origins. Read-only.
public final class SpaceMapScanner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var files: Int
        public var bytes: Int64
        public var current: String
    }

    public let root: URL
    private let home: String
    private let keepBytes: Int64
    public let cancel = CancellationFlag()
    private let files = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let unreadable = Atomic<Int>(0)
    private let current = Mutex<String>("")
    private let tracker = InodeTracker()
    private let origins = Mutex<[String: OriginTally]>([:])

    private struct OriginTally {
        var origin: Origin
        var bytes: Int64 = 0
        var count = 0
        var largest: [(path: String, bytes: Int64)] = []
    }

    private struct Inherited {
        var kind: FileKind?
        var origin: Origin?
    }

    /// Never descended into when scanning from the top of the disk.
    private static let excluded: Set<String> = ["/Volumes", "/dev", "/System/Volumes", "/private/var/vm", "/.Spotlight-V100"]

    public init(root: URL, home: URL, keepBytes: Int64 = 1_000_000) {
        self.root = root.standardizedFileURL
        self.home = home.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        self.keepBytes = max(1, keepBytes)
    }

    public var progress: Progress {
        Progress(files: files.load(ordering: .relaxed), bytes: bytes.load(ordering: .relaxed),
                 current: current.withLock { $0 })
    }

    /// Blocking. Nil when cancelled or the root isn't a readable folder.
    public func scan() -> SpaceMap? {
        let started = Date()
        let path = root.path(percentEncoded: false).trimmingSuffix("/")
        let rootPath = path.isEmpty ? "/" : path
        var st = stat()
        guard lstat(rootPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let own = FileClassifier.directory(name: root.lastPathComponent, homeRelative: homeRelative(rootPath))
        let node = scanDirectory(rootPath, name: root.lastPathComponent,
                                 inherited: Inherited(kind: own.kind, origin: own.origin), device: st.st_dev, depth: 0)
        if cancel.isCancelled { return nil }
        let totals = origins.withLock { $0.values }
            .map { OriginTotal(origin: $0.origin, bytes: $0.bytes, fileCount: $0.count, largest: $0.largest) }
            .sorted { $0.bytes > $1.bytes }
        return SpaceMap(root: node, origins: totals, fileCount: files.load(ordering: .relaxed),
                        unreadableFolders: unreadable.load(ordering: .relaxed), scannedAt: Date(),
                        duration: Date().timeIntervalSince(started))
    }

    private func homeRelative(_ path: String) -> String? {
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    private func scanDirectory(_ path: String, name: String, inherited: Inherited, device: dev_t, depth: Int) -> MapNode {
        if depth <= 3 { current.withLock { $0 = path } }
        var kept: [MapNode] = []
        var subdirectories: [(path: String, name: String)] = []
        var size = Int64(0), small = Int64(0), smallCount = 0, fileCount = 0
        var kindBytes = [Int64](repeating: 0, count: FileKind.allCases.count)
        var newest: Date?

        guard let dir = opendir(path) else {
            unreadable.add(1, ordering: .relaxed)
            return MapNode(name: name, path: path, size: 0, isDirectory: true, kind: inherited.kind ?? .other,
                           origin: inherited.origin, lastUsed: nil, children: [], smallBytes: 0, smallCount: 0,
                           kindBytes: kindBytes)
        }
        var names: [String] = []
        while let e = readdir(dir) {
            let n = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if n != "." && n != ".." { names.append(n) }
        }
        closedir(dir)

        for child in names {
            let childPath = path == "/" ? "/" + child : path + "/" + child
            var st = stat()
            guard lstat(childPath, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_dev != device || Self.excluded.contains(childPath) { continue }
                subdirectories.append((childPath, child))
                continue
            }
            var allocated = Int64(st.st_blocks) * 512
            if st.st_nlink > 1, !tracker.claim(dev: st.st_dev, ino: st.st_ino) { allocated = 0 }
            fileCount += 1
            let kind = inherited.kind ?? FileClassifier.kind(ofFile: child)
            var origin = inherited.origin ?? FileClassifier.origin(ofFile: child)
            if origin == nil, allocated >= keepBytes { origin = FileClassifier.downloadOrigin(path: childPath) }
            size += allocated
            kindBytes[kind.rawValue] += allocated
            let used = DiskSizer.entryDate(st)
            if let used { newest = max(newest ?? used, used) }
            if let origin { credit(origin, path: childPath, bytes: allocated) }
            if allocated >= keepBytes {
                kept.append(MapNode(name: child, path: childPath, size: allocated, isDirectory: false, kind: kind,
                                    origin: origin, lastUsed: used, children: [], smallBytes: 0, smallCount: 0,
                                    kindBytes: []))
            } else {
                small += allocated
                smallCount += 1
            }
        }
        files.add(fileCount, ordering: .relaxed)
        bytes.add(size, ordering: .relaxed)
        if cancel.isCancelled {
            return MapNode(name: name, path: path, size: size, isDirectory: true, kind: .other, origin: nil,
                           lastUsed: newest, children: [], smallBytes: 0, smallCount: 0, kindBytes: kindBytes)
        }

        @Sendable func descend(_ sub: (path: String, name: String)) -> MapNode {
            let says = FileClassifier.directory(name: sub.name, homeRelative: homeRelative(sub.path))
            let next = Inherited(kind: says.kind ?? inherited.kind, origin: says.origin ?? inherited.origin)
            return scanDirectory(sub.path, name: sub.name, inherited: next, device: device, depth: depth + 1)
        }
        let nodes: [MapNode]
        if depth < 2, subdirectories.count > 1 {
            // The top two levels fan out so a whole home folder is walked on every core.
            let slots = Mutex<[MapNode?]>(Array(repeating: nil, count: subdirectories.count))
            let list = subdirectories
            DispatchQueue.concurrentPerform(iterations: list.count) { i in
                let node = descend(list[i])
                slots.withLock { $0[i] = node }
            }
            nodes = slots.withLock { $0.compactMap { $0 } }
        } else {
            nodes = subdirectories.map(descend)
        }
        for node in nodes {
            size += node.size
            for k in kindBytes.indices { kindBytes[k] += node.kindBytes[k] }
            if let used = node.lastUsed { newest = max(newest ?? used, used) }
            if node.size >= keepBytes {
                kept.append(node)
            } else {
                small += node.size
                smallCount += 1
            }
        }
        kept.sort { $0.size > $1.size }
        let dominant = kindBytes.indices.max { kindBytes[$0] < kindBytes[$1] }.flatMap { kindBytes[$0] > 0 ? FileKind(rawValue: $0) : nil }
        return MapNode(name: name, path: path, size: size, isDirectory: true, kind: inherited.kind ?? dominant ?? .other,
                       origin: inherited.origin, lastUsed: newest, children: kept, smallBytes: small,
                       smallCount: smallCount, kindBytes: kindBytes)
    }

    private func credit(_ origin: Origin, path: String, bytes: Int64) {
        origins.withLock { all in
            var tally = all[origin.id] ?? OriginTally(origin: origin)
            tally.bytes += bytes
            tally.count += 1
            if tally.largest.count < 8 {
                tally.largest.append((path, bytes))
                tally.largest.sort { $0.bytes > $1.bytes }
            } else if let last = tally.largest.last, bytes > last.bytes {
                tally.largest[tally.largest.count - 1] = (path, bytes)
                tally.largest.sort { $0.bytes > $1.bytes }
            }
            all[origin.id] = tally
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > suffix.count && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
