import Foundation

enum AndroidRules {
    static var all: [Rule] { [gradle, sdk, avds] }

    static let gradle = Rule(
        id: "gradle-caches",
        title: "Gradle caches",
        category: .android,
        tier: .costsTime,
        impact: "Next Android/Gradle build re-downloads dependencies and re-runs transforms (dexing, jetifier, Kotlin compile), so it's a slow, network-hungry build. A removed wrapper dist is re-downloaded by `./gradlew`. Stop daemons first (`./gradlew --stop`).",
        recovery: "Automatically on the next Gradle build / `./gradlew` invocation.",
        regenCost: "First build afterwards ~5–15 min per project; wrapper dist ~150 MB each.",
        method: .delete,
        baseDirectories: { [$0.path(".gradle/caches"), $0.path(".gradle/daemon"), $0.path(".gradle/wrapper/dists")] },
        resolve: { ctx in
            var items: [Item] = []
            items += FS.children(of: ctx.path(".gradle/caches"), directoriesOnly: true).map {
                Item(displayName: "caches/\($0.lastPathComponent)", path: $0)
            }
            items += wholeItem(ctx.path(".gradle/daemon"), name: "daemon (logs + registry)")
            items += FS.children(of: ctx.path(".gradle/wrapper/dists"), directoriesOnly: true).map {
                Item(displayName: "wrapper \($0.lastPathComponent)", path: $0, note: "Gradle distribution used by ./gradlew")
            }
            return items
        }
    )

    static func sdkRoot(_ ctx: RuleContext) -> URL {
        if let s = ctx.environment["ANDROID_HOME"] ?? ctx.environment["ANDROID_SDK_ROOT"], !s.isEmpty,
           s.hasPrefix(ctx.home.path + "/") {
            return URL(filePath: s)
        }
        return ctx.path("Library/Android/sdk")
    }

    struct AVD {
        var name: String
        var dir: URL
        var ini: URL?
        var config: [String: String]
    }

    static func avdHome(_ ctx: RuleContext) -> URL { ctx.path(".android/avd") }

    static func listAVDs(_ ctx: RuleContext) -> [AVD] {
        let home = avdHome(ctx)
        var avds: [AVD] = []
        var claimedDirs: Set<String> = []
        for ini in FS.children(of: home).filter({ $0.pathExtension == "ini" }) {
            let values = FS.readINI(ini)
            var dir: URL?
            if let p = values["path"], FS.isDirectory(URL(filePath: p)) {
                dir = URL(filePath: p)
            } else if let rel = values["path.rel"] {
                let candidate = ctx.path(".android").appending(path: rel)
                if FS.isDirectory(candidate) { dir = candidate }
            }
            guard let dir else { continue }
            claimedDirs.insert(dir.standardizedFileURL.path)
            avds.append(AVD(name: ini.deletingPathExtension().lastPathComponent, dir: dir, ini: ini,
                            config: FS.readINI(dir.appending(path: "config.ini"))))
        }
        for dir in FS.children(of: home, directoriesOnly: true) where dir.pathExtension == "avd" {
            if claimedDirs.contains(dir.standardizedFileURL.path) { continue }
            avds.append(AVD(name: dir.deletingPathExtension().lastPathComponent, dir: dir, ini: nil,
                            config: FS.readINI(dir.appending(path: "config.ini"))))
        }
        return avds
    }

    static let sdk = Rule(
        id: "android-sdk",
        title: "Android SDK packages",
        category: .android,
        tier: .costsTime,
        impact: "Builds needing a removed platform/build-tools/NDK fail until it's reinstalled (Android Studio usually offers a one-click fix). Emulators using a removed system image won't start.",
        recovery: "Android Studio > SDK Manager, or `sdkmanager \"<package>\"`.",
        regenCost: "Re-download: system image ~1.5–3 GB, NDK ~1–2 GB, platform ~100 MB.",
        method: .delete,
        baseDirectories: { ctx in ["system-images", "platforms", "build-tools", "ndk"].map { sdkRoot(ctx).appending(path: $0) } },
        resolve: { ctx in
            let root = sdkRoot(ctx)
            var used: [String: [String]] = [:]
            for avd in listAVDs(ctx) {
                for key in ["image.sysdir.1", "image.sysdir.2"] {
                    guard var p = avd.config[key] else { continue }
                    while p.hasSuffix("/") { p.removeLast() }
                    used[p, default: []].append(avd.name)
                }
            }
            var items: [Item] = []
            // system-images/<api>/<tag>/<abi>
            for api in FS.children(of: root.appending(path: "system-images"), directoriesOnly: true) {
                for tag in FS.children(of: api, directoriesOnly: true) {
                    for abi in FS.children(of: tag, directoriesOnly: true) {
                        let rel = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                        let users = used[rel] ?? []
                        items.append(Item(
                            displayName: "System image \(api.lastPathComponent) \(tag.lastPathComponent) \(abi.lastPathComponent)",
                            path: abi,
                            note: users.isEmpty ? "not used by any AVD" : "used by AVD \(users.joined(separator: ", "))",
                            isFlagged: users.isEmpty))
                    }
                }
            }
            for (folder, label) in [("platforms", "Platform"), ("build-tools", "Build tools"), ("ndk", "NDK")] {
                items += FS.children(of: root.appending(path: folder), directoriesOnly: true).map {
                    Item(displayName: "\(label) \($0.lastPathComponent)", path: $0)
                }
            }
            return items
        }
    )

    static let avds = Rule(
        id: "android-avds",
        title: "Android emulators (AVDs)",
        category: .android,
        tier: .costsTime,
        impact: "The emulator and everything in it (installed apps, data, snapshots, Google sign-in) is gone. You'd recreate it in Device Manager and reinstall your app.",
        recovery: "Android Studio > Device Manager > Create device (or `avdmanager create avd`).",
        regenCost: "A couple of minutes to recreate + cold boot; data inside is lost.",
        method: .delete,
        baseDirectories: { [avdHome($0)] },
        resolve: { ctx in
            listAVDs(ctx).map { avd in
                let display = avd.config["avd.ini.displayname"] ?? avd.name.replacingOccurrences(of: "_", with: " ")
                let image = avd.config["image.sysdir.1"].map { "image: \($0)" }
                return Item(displayName: display, path: avd.dir,
                            companionPaths: avd.ini.map { [$0] } ?? [],
                            note: image)
            }
        }
    )
}
