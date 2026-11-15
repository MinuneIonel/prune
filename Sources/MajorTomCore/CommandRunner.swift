import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs external tools. Injected so tests never touch real tools.
public protocol CommandRunner: Sendable {
    /// Returns nil when the executable cannot be found.
    func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult?
}

/// Runs a tool via `Process` (no shell). Looks the executable up on an augmented PATH.
public struct ProcessRunner: CommandRunner {
    public var searchPath: [String]
    /// Is there an Xcode or Command Line Tools install? Without one, `/usr/bin/git`, `/usr/bin/xcrun` & co. are
    /// stubs that pop up macOS's "install the command line developer tools" dialog, so they count as not found.
    public var developerToolsInstalled: @Sendable () -> Bool = { DeveloperTools.installed() }
    /// Extra environment for every command (tests use it to isolate git from the user's global config).
    public var environmentOverrides: [String: String] = [:]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // GUI apps get a minimal PATH: add where tools usually live — Homebrew on Apple Silicon (/opt/homebrew)
        // and Intel (/usr/local), per-user installs (cargo, pnpm, Docker Desktop, OrbStack), MacPorts.
        var extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     "\(home)/.cargo/bin", "\(home)/Library/pnpm", "\(home)/.docker/bin", "\(home)/.orbstack/bin",
                     "/Applications/Docker.app/Contents/Resources/bin", "/opt/local/bin"]
        if let nodeBin = NodeVersions.activeBinDirectory(home: URL(filePath: home), environment: environment) {
            extra.append(nodeBin.path)
        }
        for p in extra where !path.contains(p) { path.append(p) }
        searchPath = path
    }

    public func locate(_ name: String) -> URL? {
        let found: URL?
        if name.hasPrefix("/") {
            found = FileManager.default.isExecutableFile(atPath: name) ? URL(filePath: name) : nil
        } else {
            found = searchPath.lazy.map { URL(filePath: $0).appending(path: name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        if let found, DeveloperTools.isStub(found.path), !developerToolsInstalled() { return nil }
        return found
    }

    public func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? {
        guard let first = argv.first, let exe = locate(first) else { return nil }
        let searchPath = self.searchPath
        let overrides = environmentOverrides
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = Array(argv.dropFirst())
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath.joined(separator: ":")
                env.merge(overrides) { _, new in new }
                process.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(returning: nil); return }

                // Read pipes concurrently so a chatty tool can't deadlock on a full pipe.
                let group = DispatchGroup()
                let box = OutputBox()
                group.enter()
                DispatchQueue.global().async {
                    box.setOut(outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    box.setErr(errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave()
                }
                var timedOut = false
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    process.terminate()
                    _ = group.wait(timeout: .now() + 2)
                }
                process.waitUntilExit()
                let (out, err) = box.values
                cont.resume(returning: CommandResult(exitCode: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut))
            }
        }
    }
}

/// Xcode / Command Line Tools presence, without running anything that could prompt to install them.
public enum DeveloperTools {
    /// `/usr/bin` tools that are only stubs until Xcode or the Command Line Tools are installed.
    static let stubs: Set<String> = ["git", "xcrun", "xcodebuild", "swift", "clang", "make", "python3", "pip3"]

    static func isStub(_ path: String) -> Bool {
        path.hasPrefix("/usr/bin/") && stubs.contains(String(path.dropFirst("/usr/bin/".count)))
    }

    /// True when the selected developer directory (`DEVELOPER_DIR`, `xcode-select -s`'s link) or one of the
    /// default locations exists.
    public static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        var candidates: [String] = []
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty { candidates.append(dir) }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(link)
        }
        candidates += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        return candidates.contains { FileManager.default.fileExists(atPath: $0 + "/usr/bin") }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func setOut(_ d: Data) { lock.withLock { out = d } }
    func setErr(_ d: Data) { lock.withLock { err = d } }
    var values: (Data, Data) { lock.withLock { (out, err) } }
}
