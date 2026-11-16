import Foundation
import MajorTomCore
import Observation

/// The space map: one walk of a folder, then zooming around the result.
@MainActor
@Observable
public final class AtlasModel {
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var scanner: SpaceMapScanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public private(set) var map: SpaceMap?
    public private(set) var isScanning = false
    public private(set) var progress: SpaceMapScanner.Progress?
    /// The folder being mapped.
    public private(set) var root: URL
    /// Path of the folder the map is zoomed into; nil = the root.
    public private(set) var focusPath: String?
    public internal(set) var message: String?

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.root = environment.context.home
    }

    public var home: URL { environment.context.home }

    public var focus: MapNode? {
        guard let map else { return nil }
        return focusPath.flatMap { map.node(at: $0) } ?? map.root
    }

    /// Root → focus.
    public var breadcrumbs: [MapNode] {
        guard let map, let focus else { return [] }
        var out = [map.root]
        var node = map.root
        while node.path != focus.path,
              let next = node.children.first(where: { focus.path == $0.path || focus.path.hasPrefix($0.path + "/") }) {
            out.append(next)
            node = next
        }
        return out
    }

    public func zoom(to node: MapNode) {
        guard node.isDirectory, !node.children.isEmpty || node.smallBytes > 0 else { return }
        focusPath = node.path
    }

    public func zoomOut() {
        let trail = breadcrumbs
        guard trail.count >= 2 else { return }
        focusPath = trail[trail.count - 2].path
    }

    public func startScan(root newRoot: URL? = nil) {
        guard !isScanning else { return }
        if let newRoot { root = newRoot.standardizedFileURL; focusPath = nil }
        let scanner = SpaceMapScanner(root: root, home: environment.context.home,
                                      keepBytes: environment.isFixture ? 50_000 : 1_000_000)
        self.scanner = scanner
        isScanning = true
        message = nil
        progress = scanner.progress
        scanTask = Task {
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    self.progress = scanner.progress
                }
            }
            let result = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
            ticker.cancel()
            if let result {
                self.map = result
                if let focusPath = self.focusPath, result.node(at: focusPath) == nil { self.focusPath = nil }
            } else if !scanner.cancel.isCancelled {
                self.message = "That folder can't be read."
            }
            self.isScanning = false
            self.progress = nil
            self.scanner = nil
        }
    }

    public func scanIfNeeded() async {
        if map == nil, !isScanning { startScan() }
        await scanTask?.value
    }

    public func cancelScan() {
        scanner?.cancel.cancel()
    }

    /// Why a node can't be moved to the Trash from the map, or nil when it can.
    public func trashRefusal(_ node: MapNode) -> String? {
        let validator = PathValidator(context: environment.context)
        let home = environment.context.home.path(percentEncoded: false).trimmingCharacters(in: ["/"])
        let path = node.path.trimmingCharacters(in: ["/"])
        if !path.hasPrefix(home + "/") { return "Only things in your home folder can be moved to the Trash from here." }
        if validator.protectedPaths.contains(where: { $0.trimmingCharacters(in: ["/"]) == path }) {
            return "This folder is part of macOS's layout and stays."
        }
        if path.hasPrefix(home + "/Library/") { return "Library items are handled under Clean Up, where each one explains what removing it costs." }
        if node.origin == .applePhotos || node.name.hasSuffix(".photoslibrary") { return "Photo libraries are managed by Photos." }
        return nil
    }

    /// Moves one item to the Trash (the fixture's own Trash folder in fixture mode), then maps again.
    public func moveToTrash(_ node: MapNode) {
        guard trashRefusal(node) == nil, !isScanning else { return }
        do {
            try environment.remover.trash(URL(filePath: node.path))
            startScan()
        } catch {
            message = "Couldn't move “\(node.name)” to the Trash: \(error.localizedDescription)"
        }
    }
}
