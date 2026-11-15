import Foundation

enum IDERules {
    static var all: [Rule] { [jetBrains] }

    /// Splits "WebStorm2025.2" into ("WebStorm", [2025, 2]).
    static func splitProductVersion(_ name: String) -> (String, [Int])? {
        guard let i = name.firstIndex(where: \.isNumber) else { return nil }
        let product = String(name[..<i])
        let version = name[i...].split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return product.isEmpty ? nil : (product, version)
    }

    static let jetBrains = Rule(
        id: "jetbrains-caches",
        title: "JetBrains caches",
        category: .ides,
        tier: .safe,
        impact: "The IDE re-indexes your projects on next open (CPU-heavy for a few minutes, search/completion degraded meanwhile). Local History lives here too and is lost. Old versions' caches are pure leftovers once you've upgraded.",
        recovery: "Automatically rebuilt when the IDE next opens a project.",
        regenCost: "Re-index per project, a few minutes each.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Caches/JetBrains")] },
        resolve: { ctx in
            let dirs = FS.children(of: ctx.path("Library/Caches/JetBrains"), directoriesOnly: true)
            var newest: [String: [Int]] = [:]
            for d in dirs {
                guard let (p, v) = splitProductVersion(d.lastPathComponent) else { continue }
                if let cur = newest[p], !cur.lexicographicallyPrecedes(v) { continue }
                newest[p] = v
            }
            return dirs.map { d in
                guard let (p, v) = splitProductVersion(d.lastPathComponent) else {
                    return Item(displayName: d.lastPathComponent, path: d)
                }
                let old = newest[p].map { v.lexicographicallyPrecedes($0) } ?? false
                return Item(displayName: d.lastPathComponent, path: d,
                            note: old ? "older than the newest \(p) version — likely a leftover" : "current \(p) version: forces a full re-index",
                            isFlagged: old)
            }
        }
    )
}

enum ContainerRules {
    static var all: [Rule] { [docker] }

    struct DFRow: Decodable {
        var `Type`: String?
        var Size: String?
        var Reclaimable: String?
        var TotalCount: String?
        var Active: String?
    }

    static let docker = Rule(
        id: "docker",
        title: "Docker",
        category: .containers,
        tier: .review,
        impact: "Pruning removes stopped containers, unused images, build cache and (with --volumes) volumes — volumes can hold database data. Docker.raw does not shrink immediately; never delete it by hand.",
        recovery: "Images re-pull / rebuild; build cache rebuilds; pruned volumes are gone for good.",
        regenCost: "Re-pull/rebuild images on demand.",
        method: .reportOnly,
        baseDirectories: { _ in [] },
        resolve: { ctx in
            guard let result = await ctx.runner.run(["docker", "system", "df", "--format", "json"], timeout: 15),
                  result.succeeded else { return [] }
            var rows: [DFRow] = []
            let dec = JSONDecoder()
            for line in result.stdout.split(separator: 0x0A) {
                if let row = try? dec.decode(DFRow.self, from: Data(line)) { rows.append(row) }
            }
            if rows.isEmpty, let arr = try? dec.decode([DFRow].self, from: result.stdout) { rows = arr }
            return rows.map { row in
                let type = row.Type ?? "?"
                var note = "reclaimable \(row.Reclaimable ?? "?")"
                if let c = row.TotalCount { note += "; \(c) total" }
                if let a = row.Active { note += ", \(a) active" }
                return Item(id: "docker-\(type)", displayName: type, path: nil,
                            size: ByteFormat.parse(row.Size ?? "0") ?? 0, note: note)
            }
        },
        actions: { _, items in
            guard !items.isEmpty else { return [] }
            return [
                RuleAction(id: "system-prune", title: "docker system prune",
                           command: ["docker", "system", "prune"], tier: .costsTime,
                           explanation: "Stopped containers, dangling images, unused networks and build cache. Asks for confirmation.", runnable: false),
                RuleAction(id: "builder-prune", title: "docker builder prune",
                           command: ["docker", "builder", "prune"], tier: .safe,
                           explanation: "Build cache only; next builds are slower.", runnable: false),
                RuleAction(id: "image-prune-all", title: "docker image prune -a",
                           command: ["docker", "image", "prune", "-a"], tier: .costsTime,
                           explanation: "Every image not used by a container; they re-pull on demand.", runnable: false),
            ]
        }
    )
}
