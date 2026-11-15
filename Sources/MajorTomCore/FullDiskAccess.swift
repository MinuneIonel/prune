import Darwin
import Foundation

/// Detects whether this process has Full Disk Access by probing TCC-protected locations.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// None of the probe locations exist, so we can't tell.
        case unknown
    }

    /// The System Settings pane where the user grants Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Paths only readable with Full Disk Access. The first one that exists decides.
    public static func probePaths(home: URL) -> [URL] {
        [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
            home.appending(path: "Library/Safari", directoryHint: .isDirectory),
            home.appending(path: ".Trash", directoryHint: .isDirectory),
        ]
    }

    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        status(probing: probePaths(home: home))
    }

    /// `EPERM`/`EACCES` on an existing probe path means no access.
    public static func status(probing paths: [URL]) -> Status {
        for url in paths {
            let path = url.path(percentEncoded: false)
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard let d = opendir(path) else { return .denied }
                closedir(d)
                return .granted
            }
            let fd = open(path, O_RDONLY)
            if fd < 0 { return .denied }
            close(fd)
            return .granted
        }
        return .unknown
    }
}
