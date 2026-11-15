import Foundation
import Testing
@testable import MajorTomCore

@Suite("Rules against a fixture home")
struct RuleTests {
    func resolve(_ rule: Rule, _ ctx: RuleContext) async throws -> [Item] { try await rule.resolve(ctx) }

    @Test func catalogueIsComplete() {
        let ids = Set(RuleCatalogue.all.map(\.id))
        #expect(ids.count == RuleCatalogue.all.count, "duplicate rule ids")
        for id in ["xcode-derived-data", "xcode-archives", "xcode-device-support", "simulator-devices", "simulator-runtimes",
                   "simulator-caches", "cocoapods-cache", "swiftpm-cache", "npm-cache", "pnpm-store", "yarn-bun-cache",
                   "nvm-node-versions", "expo-cache", "gradle-caches", "android-sdk", "android-avds", "cargo-rustup",
                   "homebrew-cache", "jetbrains-caches", "docker", "claude-desktop-data", "app-caches", "logs", "trash",
                   "local-snapshots"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        for r in RuleCatalogue.all { #expect(!r.impact.isEmpty && !r.recovery.isEmpty && !r.regenCost.isEmpty) }
    }

    @Test func missingPathsResolveToNothing() async throws {
        let f = try Fixture()
        let ctx = f.context()
        for rule in RuleCatalogue.all {
            let items = try await rule.resolve(ctx)
            #expect(items.isEmpty, "\(rule.id) found something in an empty home")
        }
    }

    @Test func derivedDataFlagsOrphans() async throws {
        let f = try Fixture()
        let live = try f.dir("WebstormProjects/App/App.xcworkspace")
        try f.plist("Library/Developer/Xcode/DerivedData/App-abc/info.plist", ["WorkspacePath": live.path])
        try f.plist("Library/Developer/Xcode/DerivedData/Gone-def/info.plist", ["WorkspacePath": f.home.path + "/old/Gone.xcodeproj"])
        try f.dir("Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
        let items = try await resolve(XcodeRules.derivedData, f.context())
        #expect(items.count == 3)
        #expect(items.first { $0.displayName == "Gone" }?.isFlagged == true)
        #expect(items.first { $0.displayName == "App" }?.isFlagged == false)
    }

    @Test func nvmNeverOffersDefaultOrActive() async throws {
        let f = try Fixture()
        for v in ["v18.20.8", "v22.20.0", "v24.21.0"] { try f.file(".nvm/versions/node/\(v)/bin/node") }
        try f.text(".nvm/alias/default", "lts/*\n")
        try f.text(".nvm/alias/lts/*", "lts/krypton\n")
        try f.text(".nvm/alias/lts/krypton", "v24.11.0\n")  // pinned patch since upgraded: same major wins
        let env = ["NVM_BIN": f.home.path + "/.nvm/versions/node/v22.20.0/bin"]
        let items = try await resolve(JavaScriptRules.nvm, f.context(environment: env))
        let protected = Set(items.filter(\.isProtected).map(\.displayName))
        #expect(protected == ["Node v24.21.0", "Node v22.20.0"])
        #expect(items.first { $0.displayName == "Node v18.20.8" }?.isProtected == false)
    }

    @Test func avdsIncludeIniAndUnusedImagesAreFlagged() async throws {
        let f = try Fixture()
        let avdDir = try f.dir(".android/avd/Pixel.avd")
        try f.text(".android/avd/Pixel_API_36.ini", "path=\(avdDir.path)\npath.rel=avd/Pixel.avd\n")
        try f.text(".android/avd/Pixel.avd/config.ini", "image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/\n")
        try f.file("Library/Android/sdk/system-images/android-36/google_apis/arm64-v8a/system.img")
        try f.file("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img")
        try f.file("Library/Android/sdk/ndk/27.0.1/x")

        let avds = try await resolve(AndroidRules.avds, f.context())
        #expect(avds.count == 1)
        #expect(avds.first?.companionPaths.map(\.lastPathComponent) == ["Pixel_API_36.ini"])

        let sdk = try await resolve(AndroidRules.sdk, f.context())
        #expect(sdk.first { $0.displayName.contains("android-35") }?.isFlagged == true)
        #expect(sdk.first { $0.displayName.contains("android-36") }?.isFlagged == false)
        #expect(sdk.contains { $0.displayName == "NDK 27.0.1" })
    }

    @Test func jetBrainsFlagsOlderVersions() async throws {
        let f = try Fixture()
        for d in ["WebStorm2025.1", "WebStorm2025.2", "Rider2025.3"] { try f.dir("Library/Caches/JetBrains/\(d)") }
        let items = try await resolve(IDERules.jetBrains, f.context())
        #expect(Set(items.filter(\.isFlagged).map(\.displayName)) == ["WebStorm2025.1"])
    }

    @Test func genericCachesSkipAppleAndCoveredFolders() async throws {
        let f = try Fixture()
        for d in ["com.apple.Safari", "CocoaPods", "Homebrew", "JetBrains", "org.swift.swiftpm", "Yarn", "com.example.app", "Google"] {
            try f.dir("Library/Caches/\(d)")
        }
        let items = try await resolve(SystemRules.genericCaches, f.context())
        #expect(Set(items.map(\.displayName)) == ["com.example.app", "Google"])
    }

    @Test func rustupDefaultToolchainIsProtected() async throws {
        let f = try Fixture()
        try f.text(".rustup/settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        try f.dir(".rustup/toolchains/stable-aarch64-apple-darwin")
        try f.dir(".rustup/toolchains/nightly-2024-01-01-aarch64-apple-darwin")
        try f.dir(".cargo/registry/cache")
        let items = try await resolve(PackageManagerRules.cargo, f.context())
        #expect(items.first { $0.displayName.contains("stable") }?.isProtected == true)
        #expect(items.first { $0.displayName.contains("nightly") }?.isProtected == false)
        #expect(items.contains { $0.displayName == "registry/cache" })
    }

    @Test func simulatorDevicesFromSimctl() async throws {
        let f = try Fixture()
        let data = try f.dir("Library/Developer/CoreSimulator/Devices/AAA/data")
        try f.file("Library/Developer/CoreSimulator/Devices/AAA/data/blob", bytes: 50_000)
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[
          {"udid":"AAA","name":"iPhone 17","state":"Shutdown","isAvailable":true,"dataPath":"\(data.path)","lastBootedAt":"2026-11-02T16:04:27Z"},
          {"udid":"BBB","name":"Old iPhone","state":"Shutdown","isAvailable":false,"dataPath":"/nonexistent"}]}}
        """
        let ctx = f.context(runner: FakeRunner(["xcrun simctl list -j devices": json]))
        let items = try await resolve(XcodeRules.simulatorDevices, ctx)
        #expect(items.count == 2)
        let aaa = try #require(items.first { $0.id == "AAA" })
        #expect(aaa.displayName == "iPhone 17 — iOS 26.1")
        #expect(aaa.methodOverride == .command(["xcrun", "simctl", "delete", "AAA"]))
        #expect(items.first { $0.id == "BBB" }?.isFlagged == true)
        let actions = XcodeRules.simulatorDevices.actions(ctx, items)
        #expect(actions.map(\.command) == [["xcrun", "simctl", "delete", "unavailable"]])
    }

    @Test func simulatorRuntimesWarnWhenOnlyOne() async throws {
        let f = try Fixture()
        let json = """
        {"X":{"identifier":"X","version":"26.1","build":"23B86","deletable":true,"sizeBytes":8344869917,
              "platformIdentifier":"com.apple.platform.iphonesimulator","lastUsedAt":"2026-11-14T21:56:15Z"}}
        """
        let items = try await resolve(XcodeRules.simulatorRuntimes,
                                      f.context(runner: FakeRunner(["xcrun simctl runtime list -j": json])))
        #expect(items.count == 1)
        #expect(items[0].size == 8_344_869_917)
        #expect(items[0].note?.contains("only iOS runtime") == true)
        #expect(items[0].methodOverride == .command(["xcrun", "simctl", "runtime", "delete", "X"]))
    }

    @Test func dockerReportOnly() async throws {
        let f = try Fixture()
        let out = """
        {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"300MB","Size":"300MB","TotalCount":"9","Type":"Build Cache"}
        """
        let ctx = f.context(runner: FakeRunner(["docker system df --format json": out]))
        let items = try await resolve(ContainerRules.docker, ctx)
        #expect(items.map(\.size) == [2_400_000_000, 300_000_000])
        #expect(ContainerRules.docker.method == .reportOnly)
        #expect(ContainerRules.docker.actions(ctx, items).allSatisfy { !$0.runnable })
    }

    @Test func npmPnpmAndExpo() async throws {
        let f = try Fixture()
        try f.file(".npm/_cacache/index-v5/x")
        try f.file(".npm/_logs/a.log")
        try f.file(".npm/other/keep")
        try f.file("Library/pnpm/store/v10/files/00/abc")
        try f.dir(".expo/schema-cache")
        try f.dir(".expo/state")
        #expect(try await resolve(JavaScriptRules.npm, f.context()).map(\.displayName) == ["_cacache", "_logs"])
        let pnpm = try await resolve(JavaScriptRules.pnpm, f.context())
        #expect(pnpm.count == 1)
        #expect(JavaScriptRules.pnpm.actions(f.context(), pnpm).first?.command == ["pnpm", "store", "prune"])
        #expect(try await resolve(JavaScriptRules.expo, f.context()).map(\.displayName) == ["schema-cache"])
    }

    @Test func claudeDataIsReportOnly() async throws {
        let f = try Fixture()
        try f.file("Library/Application Support/Claude/Cache/x")
        let items = try await resolve(SystemRules.claudeDesktop, f.context())
        #expect(items.count == 1)
        #expect(SystemRules.claudeDesktop.method == .reportOnly)
    }

    @Test func byteParsing() {
        #expect(ByteFormat.parse("2.4GB") == 2_400_000_000)
        #expect(ByteFormat.parse("512kB") == 512_000)
        #expect(ByteFormat.parse("0B") == 0)
        #expect(ByteFormat.parse("1GiB") == 1_073_741_824)
    }
}

@Suite("Scanner, settings, history")
struct InfrastructureTests {
    @Test func scannerCachesAndRescansOneRule() async throws {
        let f = try Fixture()
        try f.file("cache/a", bytes: 100_000)
        try f.file("other/b", bytes: 100_000)
        let other = Rule(id: "other", title: "o", category: .system, tier: .safe, impact: "", recovery: "", regenCost: "",
                         method: .delete, baseDirectories: { [$0.path("other")] },
                         resolve: { ctx in childItems(ctx.path("other"), directoriesOnly: false) })
        let scanner = Scanner(rules: [testRule(), other], context: f.context())
        let first = await scanner.scanAll()
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.reclaimableSize >= 100_000 })
        let otherScannedAt = try #require(await scanner.cachedResult(for: "other")?.scannedAt)

        try f.file("cache/c", bytes: 100_000)
        let re = try #require(await scanner.rescan(ruleID: "test-cache"))
        #expect(re.items.count == 2)
        #expect(await scanner.cachedResult(for: "other")?.scannedAt == otherScannedAt)
        #expect(await scanner.cachedResult(for: "test-cache")?.items.count == 2)
    }

    @Test func scanCountsSharedInodesOnceAcrossRules() async throws {
        let f = try Fixture()
        let blob = try f.file("cache/blob", bytes: 1_000_000)
        try f.dir("other")
        try FileManager.default.linkItem(at: blob, to: f.home.appending(path: "other/blob"))
        let other = Rule(id: "other", title: "o", category: .system, tier: .safe, impact: "", recovery: "", regenCost: "",
                         method: .delete, baseDirectories: { [$0.path("other")] },
                         resolve: { ctx in childItems(ctx.path("other"), directoriesOnly: false) })
        let results = await Scanner(rules: [testRule(), other], context: f.context()).scanAll()
        let total = results.reduce(Int64(0)) { $0 + $1.totalSize }
        #expect(total >= 1_000_000 && total < 1_500_000)
    }

    @Test func settingsRoundTripAndDefaults() throws {
        let f = try Fixture()
        let store = SettingsStore(url: f.root.appending(path: "settings.json"))
        #expect(store.load() == Settings())
        var s = Settings()
        s.staleAfterDays = 30
        s.projectRoots = ["~/Code"]
        try store.save(s)
        #expect(store.load() == s)
        try Data(#"{"staleAfterDays": 7}"#.utf8).write(to: store.url)
        #expect(store.load().staleAfterDays == 7)
        #expect(store.load().lowSpaceThresholdGB == 20)
        #expect(s.expandedProjectRoots(home: f.home) == [f.home.appending(path: "Code")])
    }

    @Test func historyAppendsJSONLines() throws {
        let f = try Fixture()
        let log = f.historyLog
        for i in 0..<3 {
            try log.append(HistoryEntry(id: UUID(), date: Date(), ruleIDs: ["r\(i)"], items: [],
                                        estimatedBytes: Int64(i), reclaimedBytes: Int64(i)))
        }
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(log.entries().map(\.ruleIDs) == [["r0"], ["r1"], ["r2"]])
    }
}
