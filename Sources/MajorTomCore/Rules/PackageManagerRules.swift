import Foundation

enum PackageManagerRules {
    static var all: [Rule] { [cocoaPods, swiftPM, homebrew, cargo] }

    static let cocoaPods = Rule(
        id: "cocoapods-cache",
        title: "CocoaPods cache",
        category: .packageManagers,
        tier: .safe,
        impact: "Next `pod install` downloads pod sources and specs again (slower, needs network). Existing Pods/ folders in projects are untouched.",
        recovery: "Refills automatically on the next `pod install`.",
        regenCost: "Re-download on demand; first pod install slower.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Caches/CocoaPods")] },
        resolve: { ctx in wholeItem(ctx.path("Library/Caches/CocoaPods"), name: "CocoaPods cache") }
    )

    static let swiftPM = Rule(
        id: "swiftpm-cache",
        title: "SwiftPM cache",
        category: .packageManagers,
        tier: .safe,
        impact: "Next package resolution re-clones dependency repositories and re-downloads binary artifacts. Projects keep their own checkouts in .build / DerivedData.",
        recovery: "Refills automatically on the next package resolve.",
        regenCost: "Re-clone on demand.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Caches/org.swift.swiftpm")] },
        resolve: { ctx in wholeItem(ctx.path("Library/Caches/org.swift.swiftpm"), name: "SwiftPM cache") }
    )

    static let homebrew = Rule(
        id: "homebrew-cache",
        title: "Homebrew cache",
        category: .packageManagers,
        tier: .safe,
        impact: "Old downloaded bottles and source tarballs are gone; reinstalling or downgrading a formula downloads it again. Installed software is unaffected.",
        recovery: "Re-downloaded on demand by `brew install` / `brew upgrade`.",
        regenCost: "Re-download on demand.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Caches/Homebrew")] },
        resolve: { ctx in wholeItem(ctx.path("Library/Caches/Homebrew"), name: "Homebrew downloads") },
        actions: { _, items in
            guard !items.isEmpty else { return [] }
            return [RuleAction(id: "brew-cleanup", title: "brew cleanup --prune=all",
                               command: ["brew", "cleanup", "--prune=all"], tier: .safe,
                               explanation: "Homebrew's own cleanup: removes old versions and the download cache.")]
        }
    )

    static func defaultRustToolchain(_ ctx: RuleContext) -> String? {
        if let t = ctx.environment["RUSTUP_TOOLCHAIN"], !t.isEmpty { return t }
        guard let text = FS.readText(ctx.path(".rustup/settings.toml")) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "default_toolchain" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static let cargo = Rule(
        id: "cargo-rustup",
        title: "Cargo / rustup",
        category: .packageManagers,
        tier: .costsTime,
        impact: "Registry/git caches: the next `cargo build` re-downloads and re-extracts crates (needs network). Old toolchains: projects pinned to them via rust-toolchain.toml re-download them.",
        recovery: "`cargo fetch` / next build; `rustup toolchain install <name>`.",
        regenCost: "Re-download crates on demand; ~300 MB+ per toolchain.",
        method: .delete,
        baseDirectories: { [$0.path(".cargo/registry"), $0.path(".cargo/git"), $0.path(".rustup/toolchains")] },
        resolve: { ctx in
            var items: [Item] = []
            let notes = ["cache": "downloaded .crate files", "index": "registry index", "src": "extracted crate sources"]
            for c in FS.children(of: ctx.path(".cargo/registry"), directoriesOnly: true) {
                items.append(Item(displayName: "registry/\(c.lastPathComponent)", path: c, note: notes[c.lastPathComponent]))
            }
            items += FS.children(of: ctx.path(".cargo/git"), directoriesOnly: true).map {
                Item(displayName: "git/\($0.lastPathComponent)", path: $0, note: "git dependency checkouts")
            }
            let def = defaultRustToolchain(ctx)
            for t in FS.children(of: ctx.path(".rustup/toolchains"), directoriesOnly: true) {
                let name = t.lastPathComponent
                let isDefault = def.map { name == $0 || name.hasPrefix($0 + "-") } ?? false
                items.append(Item(displayName: "toolchain \(name)", path: t,
                                  note: isDefault ? "default toolchain — never offered" : "not the default toolchain",
                                  isProtected: isDefault, isFlagged: !isDefault))
            }
            return items
        }
    )
}
