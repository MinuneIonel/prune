import Foundation

/// Caches that photo and video apps rebuild from your originals. Sources, project files and catalogs are never
/// listed here: only the derived files next to them.
enum MediaRules {
    static var all: [Rule] { [resolveRenderCache, adobeMediaCache, captureOnePreviews] }

    static let resolveRenderCache = Rule(
        id: "resolve-render-cache",
        title: "DaVinci Resolve render cache",
        category: .media,
        tier: .costsTime,
        impact: "Cached renders of effects, grades and Fusion clips. Timelines open as before, but playback of heavy clips stutters until Resolve has rendered them again in the background. Your media, projects and project backups are untouched.",
        recovery: "Resolve re-renders each clip the next time its timeline is open (red line turns blue).",
        regenCost: "Background re-render per timeline; minutes to hours for long, heavy edits.",
        method: .delete,
        baseDirectories: { [$0.path("Movies/CacheClip")] },
        resolve: { ctx in
            childItems(ctx.path("Movies/CacheClip"), directoriesOnly: false)
        }
    )

    static let adobeMediaCache = Rule(
        id: "adobe-media-cache",
        title: "Adobe media cache",
        category: .media,
        tier: .safe,
        impact: "Waveforms, conformed audio and index files Premiere Pro, After Effects and Camera Raw build for imported media. Projects open as before; the first open is slower while they're rebuilt.",
        recovery: "Rebuilt automatically when a project using the media is opened.",
        regenCost: "A slower first open per project.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Application Support/Adobe/Common"), $0.path("Library/Caches")] },
        resolve: { ctx in
            let common = ctx.path("Library/Application Support/Adobe/Common")
            return ["Media Cache Files", "Media Cache", "Peak Files"].flatMap { wholeItem(common.appending(path: $0)) }
                + wholeItem(ctx.path("Library/Caches/Adobe Camera Raw 2"), name: "Camera Raw cache")
        }
    )

    static let captureOnePreviews = Rule(
        id: "capture-one-previews",
        title: "Capture One catalog previews",
        category: .media,
        tier: .costsTime,
        impact: "The preview and thumbnail cache inside each Capture One catalog in Pictures. Your RAW files, adjustments and the catalog database are untouched; browsing the catalog is slow until previews exist again.",
        recovery: "Capture One regenerates previews as you browse, or all at once via Image › Regenerate Previews.",
        regenCost: "A few seconds per image; long for big catalogs.",
        method: .delete,
        baseDirectories: { [$0.path("Pictures")] },
        resolve: { ctx in
            FS.children(of: ctx.path("Pictures"), directoriesOnly: true)
                .filter { $0.pathExtension.lowercased() == "cocatalog" }
                .flatMap { catalog in
                    wholeItem(catalog.appending(path: "Cache"),
                              name: catalog.deletingPathExtension().lastPathComponent + " previews")
                }
        }
    )
}
