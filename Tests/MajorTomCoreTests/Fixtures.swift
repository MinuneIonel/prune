import Foundation
@testable import MajorTomCore

/// A throwaway fake home folder in the temp directory. Every test works only inside one of these.
final class Fixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "MajorTomTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        // Only ever removes our own temp directory.
        if root.path.contains("MajorTomTests-") { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func text(_ rel: String, _ content: String) throws -> URL {
        let url = home.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func dir(_ rel: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: rel, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plist(_ rel: String, _ dict: [String: Any]) throws {
        let url = home.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    func symlink(_ rel: String, to target: URL) throws {
        let url = home.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    func exists(_ url: URL) -> Bool { FS.exists(url) }

    func context(runner: any CommandRunner = FakeRunner(), environment: [String: String] = [:],
                 settings: Settings = Settings()) -> RuleContext {
        RuleContext(home: home, allowedSystemRoots: [], runner: runner, environment: environment, settings: settings)
    }

    var historyLog: HistoryLog { HistoryLog(url: root.appending(path: "history.jsonl")) }
}

/// Canned command output keyed by the space-joined argv. Records what was run.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandResult]
    private(set) var calls: [[String]] = []

    init(_ responses: [String: String] = [:]) {
        self.responses = responses.mapValues { CommandResult(exitCode: 0, stdout: Data($0.utf8)) }
    }

    func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? {
        lock.withLock {
            calls.append(argv)
            return responses[argv.joined(separator: " ")]
        }
    }

    var recordedCalls: [[String]] { lock.withLock { calls } }
}

/// A rule over `<home>/cache/*` for engine tests.
func testRule(id: String = "test-cache", tier: Tier = .safe, method: CleanMethod = .delete,
              extra: @escaping @Sendable (RuleContext) -> [Item] = { _ in [] }) -> Rule {
    Rule(id: id, title: "Test cache", category: .system, tier: tier,
         impact: "test", recovery: "test", regenCost: "none", method: method,
         baseDirectories: { [$0.path("cache")] },
         resolve: { ctx in childItems(ctx.path("cache"), directoriesOnly: false) + extra(ctx) })
}
