import Foundation

enum JavaScriptRules {
    static var all: [Rule] { [npm, pnpm, yarnBun, nvm, expo] }

    static let npm = Rule(
        id: "npm-cache",
        title: "npm cache",
        category: .javascript,
        tier: .safe,
        impact: "Next `npm install` / `npx` downloads packages again instead of copying from the cache, so the first install per project is slower and needs network. Installed node_modules are untouched.",
        recovery: "Refills automatically on the next npm install / npx run.",
        regenCost: "Re-download on demand; first installs slower.",
        method: .delete,
        baseDirectories: { [$0.path(".npm")] },
        resolve: { ctx in
            let notes = ["_cacache": "package tarball cache", "_npx": "packages fetched by npx", "_logs": "npm debug logs"]
            return ["_cacache", "_npx", "_logs"].flatMap { wholeItem(ctx.path(".npm/\($0)"), note: notes[$0]) }
        }
    )

    static func pnpmStore(_ ctx: RuleContext) -> URL { ctx.path("Library/pnpm/store") }

    static let pnpm = Rule(
        id: "pnpm-store",
        title: "pnpm store",
        category: .javascript,
        tier: .costsTime,
        impact: "Deleting the whole store breaks the hard links pnpm relies on: every project needs `pnpm install` again (and re-downloads everything). `pnpm store prune` instead only removes packages no project references — prefer that.",
        recovery: "`pnpm install` in each project re-downloads what it needs.",
        regenCost: "Full store: re-download every dependency of every project (several GB). Prune: nothing.",
        method: .delete,
        baseDirectories: { [$0.path("Library/pnpm")] },
        resolve: { ctx in
            FS.children(of: pnpmStore(ctx), directoriesOnly: true).map {
                Item(displayName: "store \($0.lastPathComponent)", path: $0,
                     note: "whole store version; prefer `pnpm store prune`")
            }
        },
        actions: { ctx, items in
            guard !items.isEmpty else { return [] }
            return [RuleAction(
                id: "prune",
                title: "Prune unreferenced packages",
                command: ["pnpm", "store", "prune"],
                tier: .safe,
                explanation: "Removes packages not referenced by any project on this Mac. Nothing needs reinstalling.")]
        }
    )

    static let yarnBun = Rule(
        id: "yarn-bun-cache",
        title: "Yarn / Bun caches",
        category: .javascript,
        tier: .safe,
        impact: "Next install with Yarn or Bun downloads packages again. Projects using Yarn PnP zero-installs keep their own cache in the repo and are unaffected.",
        recovery: "Refills automatically on the next `yarn` / `bun install`.",
        regenCost: "Re-download on demand.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Caches/Yarn"), $0.path(".yarn/berry/cache"), $0.path(".bun/install/cache")] },
        resolve: { ctx in
            wholeItem(ctx.path("Library/Caches/Yarn"), name: "Yarn classic cache")
                + wholeItem(ctx.path(".yarn/berry/cache"), name: "Yarn Berry global cache")
                + wholeItem(ctx.path(".bun/install/cache"), name: "Bun install cache")
        }
    )

    static let nvm = Rule(
        id: "nvm-node-versions",
        title: "Node versions (nvm)",
        category: .javascript,
        tier: .costsTime,
        impact: "That Node version and its globally installed npm packages (CLIs like pnpm, eas, vercel) are gone. Projects pinned to it via .nvmrc need `nvm install` again.",
        recovery: "`nvm install <version>`, then reinstall any global packages you used with it.",
        regenCost: "~1 min download per version + global packages.",
        method: .delete,
        baseDirectories: { [NodeVersions.versionsDirectory(home: $0.home)] },
        resolve: { ctx in
            let protected = NodeVersions.protectedVersions(home: ctx.home, environment: ctx.environment)
            return FS.children(of: NodeVersions.versionsDirectory(home: ctx.home), directoriesOnly: true).map {
                let v = $0.lastPathComponent
                let isProtected = protected.contains(v)
                return Item(displayName: "Node \(v)", path: $0,
                            note: isProtected ? "active/default version — never offered" : nil,
                            isProtected: isProtected)
            }
        }
    )

    static let expo = Rule(
        id: "expo-cache",
        title: "Expo caches",
        category: .javascript,
        tier: .safe,
        impact: "Expo CLI re-downloads Expo Go builds, schemas and version metadata when it next needs them. Your login and project settings stay.",
        recovery: "Automatically the next time `npx expo` needs them.",
        regenCost: "Re-download on demand (Expo Go for simulator is ~100–200 MB).",
        method: .delete,
        baseDirectories: { [$0.path(".expo")] },
        resolve: { ctx in
            FS.children(of: ctx.path(".expo"), directoriesOnly: true)
                .filter { $0.lastPathComponent.lowercased().contains("cache") }
                .map { Item(displayName: $0.lastPathComponent, path: $0) }
        }
    )
}
