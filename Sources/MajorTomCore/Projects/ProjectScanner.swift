import Darwin
import Foundation

/// Finds projects under the configured roots and works out, per project, which directories hibernation may delete.
///
/// Discovery is one cheap directory walk per root that never enters dependency/build directories. A directory
/// with `.git` always starts a project (so nested repos are separate projects); a directory with another marker
/// (`package.json`, `Podfile`, …) starts one only when it isn't already inside a project, so a monorepo's
/// `apps/*` and `packages/*` belong to the monorepo. Git is only ever queried (read-only, `--no-optional-locks`).
public struct ProjectScanner: Sendable {
    public var roots: [URL]
    public var git: any CommandRunner

    /// How deep to look for projects below a root (containers such as `web/acme-notes/…`).
    public static let maxContainerDepth = 6
    /// How deep to look inside a project for nested packages and their strippable directories.
    public static let maxProjectDepth = 10

    public init(roots: [URL], git: any CommandRunner = ProcessRunner()) {
        self.roots = roots.map(\.standardizedFileURL)
        self.git = git
    }

    public init(context: RuleContext, git: any CommandRunner = ProcessRunner()) {
        self.init(roots: context.settings.expandedProjectRoots(home: context.home), git: git)
    }

    // MARK: Public API

    /// Discovers and analyses every project (without sizes). Sorted by relative path.
    public func discover() async -> [Project] {
        let roots = self.roots
        let raw: [RawProject] = await withTaskGroup(of: [RawProject].self) { group in
            for root in roots {
                group.addTask { await Self.offPool { Walk.run(root: root, start: root) } }
            }
            var all: [RawProject] = []
            for await r in group { all += r }
            return all
        }
        // Overlapping roots can find the same project twice; keep the first.
        var seen: Set<String> = []
        let unique = raw.filter { seen.insert($0.path.path).inserted }
        let projects = await finish(unique)
        return projects.sorted { $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending }
    }

    /// Discovers projects and measures their strippable directories.
    public func scan(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Project] {
        await Self.sized(await discover(), progress: progress)
    }

    /// Re-analyses one project directory from scratch (used by the hibernate rule's resolver right before cleaning).
    /// Nil if it is not under a configured root or no longer looks like a project.
    public func analyze(projectAt url: URL) async -> Project? {
        let path = url.standardizedFileURL
        guard let root = roots.first(where: { path.path == $0.path || isStrictlyInside(path.path, $0.path) }) else { return nil }
        let raw = await Self.offPool { Walk.run(root: root, start: path) }
        guard let mine = raw.first(where: { $0.path.path == path.path }) else { return nil }
        return await finish([mine]).first
    }

    /// Fills in `size` for every strippable directory. Hard-linked files are counted once across all projects.
    public static func sized(_ projects: [Project], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Project] {
        let tracker = InodeTracker()
        let limiter = AsyncLimiter(max(4, ProcessInfo.processInfo.activeProcessorCount))
        let jobs = projects.enumerated().flatMap { p in p.element.strippable.indices.map { (p.offset, $0) } }
        let total = jobs.count
        let counter = AtomicCounter()
        var out = projects
        let sizes = await withTaskGroup(of: (Int, Int, Int64).self) { group in
            for (pi, di) in jobs {
                let url = projects[pi].strippable[di].path
                group.addTask {
                    let r = await limiter.run { await DiskSizer.size(of: url, tracker: tracker) }
                    progress?(counter.increment(), total)
                    return (pi, di, r?.allocatedBytes ?? 0)
                }
            }
            var all: [(Int, Int, Int64)] = []
            for await s in group { all.append(s) }
            return all
        }
        for (pi, di, bytes) in sizes { out[pi].strippable[di].size = bytes }
        return out
    }

    // MARK: Analysis

    private func finish(_ raws: [RawProject]) async -> [Project] {
        let limiter = AsyncLimiter(8)
        let git = self.git
        return await withTaskGroup(of: Project.self) { group in
            for raw in raws {
                group.addTask { await limiter.run { await Self.build(raw, git: git) } }
            }
            var out: [Project] = []
            for await p in group { out.append(p) }
            return out
        }
    }

    static func build(_ raw: RawProject, git: any CommandRunner) async -> Project {
        var info = GitInfo()
        if raw.isGit {
            info = await gitInfo(at: raw.path, candidates: raw.candidates, git: git)
        }
        var strippable: [StrippableDir] = []
        var skipped = raw.skipped
        for c in raw.candidates {
            var dir = StrippableDir(path: c.url, relativePath: c.rel, kind: c.kind, reason: c.reason)
            if info.trackedCandidates.contains(c.rel) {
                dir.reason = "contains files tracked by git"
                skipped.append(dir)
                continue
            }
            if c.kind == .buildOutput {
                let ignored = info.ignoredCandidates.contains(c.rel)
                switch (ignored, c.frameworkReason) {
                case (true, let fw?): dir.reason = "ignored by git; \(fw)"
                case (true, nil): dir.reason = "ignored by git"
                case (false, let fw?): dir.reason = fw
                case (false, nil):
                    dir.reason = "not ignored by git and not a known build output"
                    skipped.append(dir)
                    continue
                }
            }
            strippable.append(dir)
        }
        strippable.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        var notes: [String] = []
        if strippable.contains(where: { $0.kind == .nodeModules && FS.exists($0.path.appending(path: ".pnpm")) }) {
            notes.append("pnpm hard-links node_modules to its store: less is freed until `pnpm store prune`.")
        }
        let rel: String
        if raw.path.path == raw.root.path {
            rel = raw.path.lastPathComponent
        } else {
            rel = String(raw.path.path.dropFirst(raw.root.path.count + 1))
        }
        return Project(path: raw.path, root: raw.root, relativePath: rel, markers: raw.markers, isGitRepo: raw.isGit,
                       lastCommit: info.lastCommit, newestFileChange: raw.newest, git: raw.isGit ? info.state : nil,
                       strippable: strippable, skipped: skipped,
                       restoreCommands: restoreCommands(raw: raw, strippable: strippable), notes: notes)
    }

    /// Dependency install commands, chosen from the nearest lockfile (JS first, then CocoaPods).
    static func restoreCommands(raw: RawProject, strippable: [StrippableDir]) -> [String] {
        var js: [String] = []
        var pods: [String] = []
        func cdPrefix(_ rel: String) -> String { rel.isEmpty ? "" : "cd \(shellQuote(rel)) && " }
        for dir in strippable {
            let parent = parentRel(dir.relativePath)
            switch dir.kind {
            case .nodeModules:
                var d: String? = parent
                var command: String?
                while let cur = d {
                    if let tool = raw.lockfiles[cur].flatMap(packageManager(forLockfiles:)) {
                        command = cdPrefix(cur) + tool + " install"
                        break
                    }
                    d = cur.isEmpty ? nil : parentRel(cur)
                }
                if command == nil {
                    let tool = raw.packageManagerField.map { String($0.prefix { $0 != "@" }) } ?? "npm"
                    command = cdPrefix(parent) + tool + " install"
                }
                if let command, !js.contains(command) { js.append(command) }
            case .pods:
                let command = cdPrefix(parent) + "pod install"
                if !pods.contains(command) { pods.append(command) }
            default:
                break
            }
        }
        return js + pods
    }

    static func packageManager(forLockfiles names: Set<String>) -> String? {
        if names.contains("pnpm-lock.yaml") { return "pnpm" }
        if names.contains("yarn.lock") { return "yarn" }
        if names.contains("bun.lock") || names.contains("bun.lockb") { return "bun" }
        if names.contains("package-lock.json") || names.contains("npm-shrinkwrap.json") { return "npm" }
        return nil
    }

    static func parentRel(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }

    // MARK: Git (read-only)

    struct GitInfo {
        var lastCommit: Date?
        var state = GitState()
        var trackedCandidates: Set<String> = []
        var ignoredCandidates: Set<String> = []
    }

    static func gitInfo(at path: URL, candidates: [RawProject.Candidate], git: any CommandRunner) async -> GitInfo {
        let plain = ["git", "--no-optional-locks", "-C", path.path, "-c", "core.quotepath=off"]
        // Candidate paths may contain glob characters ("[02] …"); check-ignore rejects this flag, so it uses `plain`.
        let base = plain + ["--literal-pathspecs"]
        let rels = candidates.map(\.rel)
        let buildRels = candidates.filter { $0.kind == .buildOutput }.map(\.rel)
        async let log = git.run(base + ["log", "-1", "--format=%ct"], timeout: 15)
        async let status = git.run(base + ["status", "--porcelain=v2", "--branch"], timeout: 30)
        async let unpushed = git.run(base + ["rev-list", "--count", "--branches", "--not", "--remotes"], timeout: 15)
        async let remotes = git.run(base + ["remote"], timeout: 15)
        async let tracked = rels.isEmpty ? nil : git.run(base + ["ls-files", "-z", "--"] + rels, timeout: 30)
        async let ignored = buildRels.isEmpty ? nil : git.run(plain + ["check-ignore", "--"] + buildRels, timeout: 15)

        var info = GitInfo()
        if let r = await log, r.succeeded, let t = TimeInterval(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            info.lastCommit = Date(timeIntervalSince1970: t)
        }
        if let r = await status, r.succeeded {
            for line in r.stdoutString.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("# branch.head ") {
                    let b = String(line.dropFirst("# branch.head ".count))
                    info.state.branch = b == "(detached)" ? nil : b
                } else if !line.hasPrefix("#") {
                    info.state.uncommittedChanges += 1
                }
            }
        }
        if let r = await remotes, r.succeeded {
            info.state.hasRemote = !r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let r = await unpushed, r.succeeded {
            info.state.unpushedCommits = Int(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        if let r = await tracked {
            if r.succeeded {
                let files = r.stdoutString.split(separator: "\0").map(String.init)
                for rel in rels where files.contains(where: { $0 == rel || $0.hasPrefix(rel + "/") }) {
                    info.trackedCandidates.insert(rel)
                }
            } else {
                // If git can't tell us, assume the worst: nothing in this repo is safe to strip.
                info.trackedCandidates = Set(rels)
            }
        }
        // check-ignore exits 1 when nothing is ignored; only exit 0 lists ignored paths.
        if let r = await ignored, r.exitCode == 0, !r.timedOut {
            let lines = Set(r.stdoutString.split(whereSeparator: \.isNewline).map { clean(String($0)) })
            info.ignoredCandidates = Set(buildRels.filter { lines.contains($0) })
        }
        return info
    }

    // MARK: Helpers

    static func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: body()) }
        }
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// A project as the walk found it, before git has been asked anything.
final class RawProject: @unchecked Sendable {
    struct Candidate: Sendable {
        var url: URL
        var rel: String
        var kind: StrippableDir.Kind
        var reason: String
        /// For `dist`/`build`: why it's a known framework output, if it is.
        var frameworkReason: String?
    }

    let path: URL
    let root: URL
    let isGit: Bool
    var markers: [String]
    var newest: Date?
    var candidates: [Candidate] = []
    var skipped: [StrippableDir] = []
    /// Lockfiles per directory (relative to the project, "" = project root).
    var lockfiles: [String: Set<String>] = [:]
    /// `packageManager` field of the project's root package.json (e.g. "pnpm@9.1.0").
    var packageManagerField: String?

    init(path: URL, root: URL, isGit: Bool, markers: [String]) {
        self.path = path
        self.root = root
        self.isGit = isGit
        self.markers = markers
    }

    func rel(_ absolute: String) -> String {
        absolute == path.path ? "" : String(absolute.dropFirst(path.path.count + 1))
    }
}

/// The synchronous directory walk behind discovery.
enum Walk {
    static let markerFiles: [String] = [
        "package.json", "Podfile", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "Cargo.toml", "Package.swift", "pubspec.yaml", "go.mod", "pyproject.toml", "requirements.txt", "Gemfile",
        "pom.xml", "composer.json", "deno.json",
    ]
    static let markerExtensions: [String] = [".xcodeproj", ".xcworkspace"]
    static let lockfileNames: Set<String> = [
        "pnpm-lock.yaml", "yarn.lock", "package-lock.json", "npm-shrinkwrap.json", "bun.lock", "bun.lockb",
    ]
    /// Never entered: dependencies, caches, build outputs, VCS and IDE state.
    static let neverDescend: Set<String> = [
        ".git", "node_modules", "Pods", ".next", ".expo", ".turbo", ".gradle", "DerivedData", ".build", ".swiftpm",
        ".venv", "venv", "__pycache__", ".cache", ".idea", ".yarn", ".pnpm-store", "bower_components", "vendor",
        "build", "dist", "out", "coverage", ".parcel-cache", ".svelte-kit", ".nuxt", ".output", ".vercel",
        ".firebase", ".dart_tool", "target", ".cxx", ".Trash",
    ]

    static func markers(in names: Set<String>) -> [String] {
        var out = markerFiles.filter(names.contains)
        out += names.filter { n in markerExtensions.contains { n.hasSuffix($0) } }.sorted()
        return out
    }

    /// Walks `start` (inside `root`) and returns every project found.
    static func run(root: URL, start: URL) -> [RawProject] {
        var projects: [RawProject] = []
        var st = stat()
        guard lstat(start.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        let startDepth = start.path == root.path ? 0 : start.path.dropFirst(root.path.count).split(separator: "/").count
        visit(start.path, root: root, dev: st.st_dev, owner: nil, depth: startDepth, ownerDepth: 0, into: &projects)
        return projects
    }

    private static func visit(_ dir: String, root: URL, dev: dev_t, owner: RawProject?, depth: Int, ownerDepth: Int,
                              into projects: inout [RawProject]) {
        let names = DiskSizer.listDirectory(dir)
        let nameSet = Set(names)
        var owner = owner
        var ownerDepth = ownerDepth
        let found = markers(in: nameSet)
        if nameSet.contains(".git") && owner?.path.path != dir {
            owner = RawProject(path: URL(filePath: dir, directoryHint: .isDirectory).standardizedFileURL, root: root,
                               isGit: true, markers: [".git"] + found)
            ownerDepth = 0
            projects.append(owner!)
        } else if owner == nil, !found.isEmpty {
            owner = RawProject(path: URL(filePath: dir, directoryHint: .isDirectory).standardizedFileURL, root: root,
                               isGit: false, markers: found)
            ownerDepth = 0
            projects.append(owner!)
        }

        if let o = owner {
            let locks = nameSet.intersection(lockfileNames)
            if !locks.isEmpty { o.lockfiles[o.rel(dir)] = locks }
            if dir == o.path.path, nameSet.contains("package.json"),
               let field = packageJSON(dir)?["packageManager"] as? String {
                o.packageManagerField = field
            }
        }

        for name in names {
            if name == ".git" { continue }
            let child = dir + "/" + name
            var st = stat()
            guard lstat(child, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            if type == S_IFREG {
                if let o = owner, !FS.ignoredNames.contains(name) {
                    let m = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
                    if o.newest.map({ m > $0 }) ?? true { o.newest = m }
                }
                continue
            }
            guard type == S_IFDIR, st.st_dev == dev else { continue }  // no symlinks, no other volumes
            if let o = owner {
                if let candidate = candidate(name: name, path: child, parentDir: dir, parentNames: nameSet, owner: o) {
                    switch candidate {
                    case .strip(let c): o.candidates.append(c)
                    case .skip(let s): o.skipped.append(s)
                    }
                    continue
                }
            }
            if neverDescend.contains(name) { continue }
            if owner == nil ? depth >= ProjectScanner.maxContainerDepth : ownerDepth >= ProjectScanner.maxProjectDepth { continue }
            visit(child, root: root, dev: dev, owner: owner, depth: depth + 1, ownerDepth: ownerDepth + 1, into: &projects)
        }
    }

    enum CandidateResult {
        case strip(RawProject.Candidate)
        case skip(StrippableDir)
    }

    /// Is `name` (a directory inside a project) something hibernation may remove?
    static func candidate(name: String, path: String, parentDir: String, parentNames: Set<String>,
                          owner: RawProject) -> CandidateResult? {
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        let rel = owner.rel(path)
        func strip(_ kind: StrippableDir.Kind, _ reason: String, framework: String? = nil) -> CandidateResult {
            .strip(.init(url: url, rel: rel, kind: kind, reason: reason, frameworkReason: framework))
        }
        func skip(_ kind: StrippableDir.Kind, _ reason: String) -> CandidateResult {
            .skip(StrippableDir(path: url, relativePath: rel, kind: kind, reason: reason))
        }
        // A directory with its own .git is a nested repository, never a strippable directory.
        if FS.exists(url.appending(path: ".git")) { return nil }

        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]
            .contains(where: parentNames.contains)
        switch name {
        case "node_modules":
            return strip(.nodeModules, "installed npm packages")
        case "Pods":
            return parentNames.contains("Podfile") ? strip(.pods, "installed CocoaPods (Podfile next to it)") : nil
        case ".next":
            return strip(.nextCache, "Next.js build output and cache")
        case ".expo":
            return strip(.expoCache, "Expo CLI state, recreated on the next start")
        case ".turbo":
            return strip(.turboCache, "Turborepo cache")
        case ".gradle":
            return gradle ? strip(.gradleCache, "Gradle project cache") : nil
        case ".cxx":
            return gradle ? strip(.gradleCache, "Android NDK / CMake build intermediates") : nil
        case "target":
            if parentNames.contains("Cargo.toml") { return strip(.cargoTarget, "Cargo build output") }
            if parentNames.contains("pom.xml") { return strip(.mavenTarget, "Maven build output") }
            return nil
        case ".build":
            return parentNames.contains("Package.swift") ? strip(.swiftBuild, "SwiftPM build output") : nil
        case "build", "dist":
            if containsEnvFile(path) { return skip(.buildOutput, "contains a .env file") }
            let fw = frameworkOutput(name: name, parentDir: parentDir, parentNames: parentNames, gradle: gradle)
            if owner.isGit { return strip(.buildOutput, fw ?? "build output", framework: fw) }
            guard let fw else { return skip(.buildOutput, "not clearly a build output (no git to ask, no known framework)") }
            return strip(.buildOutput, fw, framework: fw)
        default:
            return nil
        }
    }

    /// `.env`, `.env.local`, … directly inside, or one level down.
    static func containsEnvFile(_ dir: String) -> Bool {
        for name in DiskSizer.listDirectory(dir) {
            if name.hasPrefix(".env") { return true }
            let child = dir + "/" + name
            if FS.isDirectory(URL(filePath: child)), DiskSizer.listDirectory(child).contains(where: { $0.hasPrefix(".env") }) {
                return true
            }
        }
        return false
    }

    /// Why a `dist`/`build` directory is a known framework's output, or nil if it isn't clearly one.
    static func frameworkOutput(name: String, parentDir: String, parentNames: Set<String>, gradle: Bool) -> String? {
        if name == "build" {
            if gradle { return "Gradle build output" }
            if parentNames.contains("Podfile") || parentNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return "Xcode build output"
            }
            if parentNames.contains("pubspec.yaml") { return "Flutter build output" }
        }
        if name == "dist", parentNames.contains(where: { $0.hasPrefix("vite.config.") }) { return "Vite build output" }
        if parentNames.contains("package.json"), let text = FS.readText(URL(filePath: parentDir + "/package.json")) {
            let deps = name == "build"
                ? [("react-scripts", "Create React App"), ("@docusaurus/core", "Docusaurus")]
                : [("vite", "Vite"), ("electron-builder", "electron-builder"), ("tsup", "tsup"), ("parcel", "Parcel"),
                   ("webpack", "webpack"), ("rollup", "Rollup")]
            for (dep, label) in deps where text.contains("\"\(dep)\"") { return "\(label) build output" }
        }
        if parentNames.contains("tsconfig.json"), let text = FS.readText(URL(filePath: parentDir + "/tsconfig.json")),
           text.range(of: #""outDir"\s*:\s*"(\./)?\#(name)/?""#, options: .regularExpression) != nil {
            return "TypeScript output (tsconfig outDir)"
        }
        return nil
    }

    static func packageJSON(_ dir: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(filePath: dir + "/package.json")), data.count < 1_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
