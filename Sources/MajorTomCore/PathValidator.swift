import Darwin
import Foundation

public enum PathValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAbsolute(String)
    case relativeComponents(String)
    case outsideAllowedRoots(String)
    case protectedLocation(String)
    case volumeRoot(String)
    case projectRoot(String)
    case outsideRuleBase(String)
    case symlinkEscape(String)
    case missing(String)
    case insideProject(String)
    case insidePackage(String)
    case managedLibrary(String)

    public var description: String {
        switch self {
        case .notAbsolute(let p): "not an absolute path: \(p)"
        case .relativeComponents(let p): "path contains . or .. components: \(p)"
        case .outsideAllowedRoots(let p): "outside the home folder and allow-listed system paths: \(p)"
        case .protectedLocation(let p): "protected location: \(p)"
        case .volumeRoot(let p): "volume root: \(p)"
        case .projectRoot(let p): "project root (has .git or is a configured project root): \(p)"
        case .outsideRuleBase(let p): "not inside the rule's base directory: \(p)"
        case .symlinkEscape(let p): "reached through a symlink that escapes the rule's base directory: \(p)"
        case .missing(let p): "does not exist: \(p)"
        case .insideProject(let p): "inside a project or git repository: \(p)"
        case .insidePackage(let p): "inside an app bundle, library or other package: \(p)"
        case .managedLibrary(let p): "a Photos/Music/TV-style library managed by an app: \(p)"
        }
    }
}

/// Re-validates a path immediately before it is cleaned (spec, hard safety rule 3).
public struct PathValidator: Sendable {
    public var home: URL
    public var allowedSystemRoots: [URL]
    public var projectRoots: [URL]

    public init(home: URL, allowedSystemRoots: [URL], projectRoots: [URL] = []) {
        self.home = home.standardizedFileURL
        self.allowedSystemRoots = allowedSystemRoots.map(\.standardizedFileURL)
        self.projectRoots = projectRoots.map(\.standardizedFileURL)
    }

    public init(context: RuleContext) {
        self.init(home: context.home,
                  allowedSystemRoots: context.allowedSystemRoots,
                  projectRoots: context.settings.expandedProjectRoots(home: context.home))
    }

    /// Locations that must never be removed themselves, whatever a rule says.
    public var protectedPaths: [String] {
        let h = clean(home.path)
        let rel = ["", "Library", "Library/Caches", "Library/Application Support", "Library/Developer",
                   "Library/Developer/Xcode", "Library/Preferences", "Library/Containers", "Library/Mobile Documents",
                   "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
                   ".ssh", ".gnupg", ".config", ".Trash"]
        return rel.map { $0.isEmpty ? h : h + "/" + $0 } + allowedSystemRoots.map { clean($0.path) } + ["/"]
    }

    /// `allowRepositoryRoot` is only for NAS offload, which moves a whole (stale) project — `.git` included — to the
    /// Trash after it has been copied and verified. Configured project roots are refused either way.
    public func validate(_ url: URL, bases: [URL], allowRepositoryRoot: Bool = false) throws(PathValidationError) {
        let raw = url.path(percentEncoded: false)
        guard raw.hasPrefix("/") else { throw .notAbsolute(raw) }
        let comps = raw.split(separator: "/", omittingEmptySubsequences: true)
        if comps.contains(where: { $0 == "." || $0 == ".." }) { throw .relativeComponents(raw) }
        let path = clean(raw)

        // 1. Inside home or an allow-listed system root (strictly inside).
        let anchors = [clean(home.path)] + allowedSystemRoots.map { clean($0.path) }
        guard let anchor = anchors.first(where: { isStrictlyInside(path, $0) }) else { throw .outsideAllowedRoots(path) }

        // 2. Never a protected location, volume root, or project root.
        if protectedPaths.contains(path) { throw .protectedLocation(path) }
        if path == "/" || isVolumeRoot(path) { throw .volumeRoot(path) }
        if projectRoots.map({ clean($0.path) }).contains(path) { throw .projectRoot(path) }

        // 3. Must exist (lstat: the item itself may be a symlink; removing it only removes the link).
        var st = stat()
        guard lstat(path, &st) == 0 else { throw .missing(path) }
        if !allowRepositoryRoot, (st.st_mode & S_IFMT) == S_IFDIR, FileManager.default.fileExists(atPath: path + "/.git") {
            throw .projectRoot(path)
        }

        // 4. Lexically inside (or equal to) one of the rule's base directories.
        let cleanBases = bases.map { clean($0.standardizedFileURL.path) }
        guard let base = cleanBases.first(where: { path == $0 || isStrictlyInside(path, $0) }) else {
            throw .outsideRuleBase(path)
        }

        // 5. No symlink on the way escapes the base (or, for the base itself, the anchor).
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = realPath(parent), let realAnchor = realPath(anchor) else { throw .missing(path) }
        if !(realParent == realAnchor || isStrictlyInside(realParent, realAnchor)) { throw .symlinkEscape(path) }
        if path != base {
            guard let realBase = realPath(base) else { throw .missing(base) }
            if !(realBase == realAnchor || isStrictlyInside(realBase, realAnchor)) { throw .symlinkEscape(path) }
            if !(realParent == realBase || isStrictlyInside(realParent, realBase)) { throw .symlinkEscape(path) }
        }
    }

    /// Extra checks for trash-only rules over user files: the path must not be a managed library, and nothing
    /// between the rule's base and the path may be a project root, git repository, configured project root
    /// or package (app bundle, library, …). Call after `validate(_:bases:)`.
    public func validateUserFile(_ url: URL, bases: [URL]) throws(PathValidationError) {
        let path = clean(url.path(percentEncoded: false))
        if UserFilesPolicy.isManagedLibrary(name: (path as NSString).lastPathComponent) { throw .managedLibrary(path) }
        let cleanBases = bases.map { clean($0.standardizedFileURL.path) }
        guard let base = cleanBases.filter({ path == $0 || isStrictlyInside(path, $0) }).max(by: { $0.count < $1.count })
        else { throw .outsideRuleBase(path) }
        let roots = Set(projectRoots.map { clean($0.path) })
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > base.count, isStrictlyInside(dir, base) {
            let name = (dir as NSString).lastPathComponent
            if roots.contains(dir) || UserFilesPolicy.isProjectDirectory(dir) { throw .insideProject(path) }
            if UserFilesPolicy.isPackage(name: name, path: dir) { throw .insidePackage(path) }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    private func isVolumeRoot(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mount = withUnsafePointer(to: fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if mount == path { return true }
        let comps = path.split(separator: "/")
        return comps.count == 2 && comps[0] == "Volumes"
    }
}

func clean(_ path: String) -> String {
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}

func isStrictlyInside(_ path: String, _ root: String) -> Bool {
    let r = clean(root)
    if r == "/" { return path != "/" && path.hasPrefix("/") }
    return path.hasPrefix(r + "/")
}

func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return clean(String(cString: r))
}
