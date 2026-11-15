import Foundation

enum FS {
    static let ignoredNames: Set<String> = [".DS_Store", ".localized", "CACHEDIR.TAG"]

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0
    }

    /// True for real directories only (symlinks are not followed).
    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Direct children (including hidden ones except Finder litter), sorted by name.
    static func children(of url: URL, directoriesOnly: Bool = false) -> [URL] {
        guard isDirectory(url) else { return [] }
        return DiskSizer.listDirectory(url.path(percentEncoded: false))
            .filter { !ignoredNames.contains($0) }
            .sorted()
            .map { url.appending(path: $0, directoryHint: .notDirectory) }
            .filter { !directoriesOnly || isDirectory($0) }
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Parses simple `key=value` files (AVD .ini / config.ini).
    static func readINI(_ url: URL) -> [String: String] {
        guard let text = readText(url) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[k] = v
        }
        return out
    }
}

/// One item per direct child of `dir` (or a single item for `dir` itself when `whole`).
func childItems(_ dir: URL, directoriesOnly: Bool = true, note: ((URL) -> String?)? = nil) -> [Item] {
    FS.children(of: dir, directoriesOnly: directoriesOnly).map {
        Item(displayName: $0.lastPathComponent, path: $0, note: note?($0))
    }
}

func wholeItem(_ dir: URL, name: String? = nil, note: String? = nil) -> [Item] {
    guard FS.exists(dir) else { return [] }
    return [Item(displayName: name ?? dir.lastPathComponent, path: dir, note: note)]
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = 0
        while abs(value) >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        if i == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    /// Parses Docker-style sizes such as "2.31GB", "512kB", "0B", "1.2 GiB".
    public static func parse(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let split = t.firstIndex(where: { !($0.isNumber || $0 == ".") }) else { return Int64(Double(t) ?? 0) }
        guard let number = Double(t[..<split]) else { return nil }
        let unit = t[split...].trimmingCharacters(in: .whitespaces).lowercased()
        let mult: Double = switch unit {
        case "b": 1
        case "kb", "k": 1e3
        case "mb", "m": 1e6
        case "gb", "g": 1e9
        case "tb", "t": 1e12
        case "kib": 1024
        case "mib": 1024 * 1024
        case "gib": 1024 * 1024 * 1024
        case "tib": 1024 * 1024 * 1024 * 1024
        default: 1
        }
        return Int64(number * mult)
    }
}

/// Node versions installed by nvm and which one is active/default.
public enum NodeVersions {
    public static func versionsDirectory(home: URL) -> URL { home.appending(path: ".nvm/versions/node") }

    /// The bin dir of the node in use: `NVM_BIN`, else the first PATH entry inside nvm, else the default alias.
    public static func activeBinDirectory(home: URL, environment: [String: String]) -> URL? {
        if let bin = environment["NVM_BIN"], !bin.isEmpty { return URL(filePath: bin) }
        let root = versionsDirectory(home: home).path
        for p in (environment["PATH"] ?? "").split(separator: ":") where p.hasPrefix(root + "/") {
            return URL(filePath: String(p))
        }
        if let v = defaultVersion(home: home) { return versionsDirectory(home: home).appending(path: "\(v)/bin") }
        return nil
    }

    /// Installed version names (e.g. "v24.21.0") that must never be offered: the default alias and the
    /// active one (`NVM_BIN`, else the first nvm entry on PATH).
    public static func protectedVersions(home: URL, environment: [String: String]) -> Set<String> {
        var out: Set<String> = []
        if let d = defaultVersion(home: home) { out.insert(d) }
        let root = versionsDirectory(home: home).path + "/"
        let active = environment["NVM_BIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["PATH"] ?? "").split(separator: ":").map(String.init).first { $0.hasPrefix(root) }
        if let active, active.hasPrefix(root), let v = active.dropFirst(root.count).split(separator: "/").first {
            out.insert(String(v))
        }
        return out
    }

    /// Resolves `~/.nvm/alias/default` (following alias chains such as `lts/*` -> `lts/krypton` -> `v24`)
    /// to the newest installed version matching it.
    public static func defaultVersion(home: URL) -> String? {
        let aliasDir = home.appending(path: ".nvm/alias")
        var target = "default"
        var seen: Set<String> = []
        while !seen.contains(target) {
            seen.insert(target)
            let file = aliasDir.appending(path: target)
            guard let text = FS.readText(file)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { break }
            target = text
        }
        let installed = FS.children(of: versionsDirectory(home: home), directoriesOnly: true).map(\.lastPathComponent)
        var want = target
        if want == "node" || want == "stable" || want.hasPrefix("lts/") {
            // Unresolvable alias: newest installed.
            return installed.max(by: versionLess)
        }
        if !want.hasPrefix("v") { want = "v" + want }
        let matches = installed.filter { $0 == want || $0.hasPrefix(want + ".") }
        if let best = matches.max(by: versionLess) { return best }
        // LTS aliases pin an exact version that may since have been upgraded within the same major.
        let major = want.split(separator: ".").first.map(String.init) ?? want
        return installed.filter { $0 == major || $0.hasPrefix(major + ".") }.max(by: versionLess)
    }

    static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        return pa.lexicographicallyPrecedes(pb)
    }
}
