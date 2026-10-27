import Darwin
import Foundation

/// What a path was when the user confirmed deleting it. Deletion refuses a path that has
/// changed since (replaced by another file, or by a link), so what's deleted is what was shown.
public struct FileIdentity: Sendable, Equatable {
    public var device: Int32
    public var inode: UInt64
    public var type: mode_t

    public static func of(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, type: info.st_mode & S_IFMT)
    }
}

public struct RemovalTarget: Sendable, Equatable {
    public var path: String
    public var identity: FileIdentity
}

public enum RemovalError: Error, Equatable, Sendable {
    case outsideAllowedRoot
    case neverDeletable
    case missing
    case changed
    case reachedThroughLink
    /// Some entries couldn't be removed; the count and the first reason.
    case incomplete(failures: Int, first: String)

    public var message: String {
        switch self {
        case .outsideAllowedRoot: "outside the folder this run may change"
        case .neverDeletable: "a protected location"
        case .missing: "already gone"
        case .changed: "changed since it was checked; left alone"
        case .reachedThroughLink: "reached through a symbolic link; left alone"
        case let .incomplete(failures, first): "\(failures) item\(failures == 1 ? "" : "s") inside couldn't be removed (\(first))"
        }
    }
}

/// The only code in delete that removes files.
public enum Remover {
    /// Removes one confirmed target permanently. A folder is removed bottom-up without following
    /// symbolic links (a link is removed, never what it points to) and without crossing into
    /// another volume mounted inside it.
    public static func remove(_ target: RemovalTarget, allowedRoot: String, home: URL) -> Result<Void, RemovalError> {
        let path = target.path
        // Lexically clean: absolute, no empty, "." or ".." components. (Not via Foundation, whose
        // standardizing rewrites /private/var to /var.)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), path.count > 1, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .failure(.outsideAllowedRoot) }
        let root = allowedRoot == "/" ? "" : allowedRoot
        guard root.isEmpty || path.hasPrefix(root + "/") else { return .failure(.outsideAllowedRoot) }
        guard !isNeverDeletable(String(path.dropFirst(root.count)), home: home, root: root) else { return .failure(.neverDeletable) }
        guard let current = FileIdentity.of(path) else { return .failure(.missing) }
        guard current == target.identity else { return .failure(.changed) }
        // The folder holding it must be where its path says, not somewhere a link leads.
        let parent = (path as NSString).deletingLastPathComponent
        guard let real = realpath(parent, nil) else { return .failure(.missing) }
        defer { free(real) }
        let resolvedParent = String(cString: real)
        guard resolvedParent == parent || isSystemLink(parent, resolved: resolvedParent) else { return .failure(.reachedThroughLink) }

        if current.type != S_IFDIR {
            return unlink(path) == 0 || errno == ENOENT ? .success(()) : .failure(.incomplete(failures: 1, first: String(cString: strerror(errno))))
        }
        return removeTree(path, device: current.device)
    }

    /// Removes a folder only if nothing is in it but a `.DS_Store`: Homebrew's `rmdir`. True when
    /// it was removed. Anything else (contents, a link, a protected folder) leaves it alone.
    public static func removeIfEmpty(_ path: String, allowedRoot: String, home: URL) -> Bool {
        let root = allowedRoot == "/" ? "" : allowedRoot
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              root.isEmpty || path.hasPrefix(root + "/"),
              !isNeverDeletable(String(path.dropFirst(root.count)), home: home, root: root),
              !Protection.standardLibraryFolders.contains(URL(filePath: path).lastPathComponent.lowercased()) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path), names.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        if names.contains(".DS_Store") { unlink(path + "/.DS_Store") }
        return rmdir(path) == 0
    }

    private static func removeTree(_ path: String, device: Int32) -> Result<Void, RemovalError> {
        let copy = strdup(path)
        defer { free(copy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .failure(.incomplete(failures: 1, first: String(cString: strerror(errno)))) }
        defer { fts_close(stream) }
        var failures = 0
        var first: String?
        func fail(_ entry: UnsafeMutablePointer<FTSENT>, _ code: Int32) {
            failures += 1
            guard first == nil else { return }
            // Named inside the item ("locked/file"), which the report already shows.
            let full = String(cString: entry.pointee.fts_path)
            let inside = full.hasPrefix(path + "/") ? String(full.dropFirst(path.count + 1)) : full
            first = "\(inside.terminalInline): \(String(cString: strerror(code)))"
        }
        while let entry = fts_read(stream) {
            let entryPath = entry.pointee.fts_path!
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                // A volume mounted inside is never entered (FTS_XDEV); it's reported when its
                // folder can't be removed.
                if let info = entry.pointee.fts_statp?.pointee, info.st_dev != device { fts_set(stream, entry, FTS_SKIP); fail(entry, EXDEV) }
            case FTS_DP:
                // A folder left non-empty by a failure inside it isn't another failure.
                if rmdir(entryPath) != 0, errno != ENOENT, !(errno == ENOTEMPTY && failures > 0) { fail(entry, errno) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                fail(entry, entry.pointee.fts_errno)
            default:
                // Files, symbolic links (never followed), and anything else that isn't a folder.
                if unlink(entryPath) != 0, errno != ENOENT { fail(entry, errno) }
            }
        }
        return failures == 0 ? .success(()) : .failure(.incomplete(failures: failures, first: first ?? "unknown"))
    }

    /// The last line of defence, independent of how a path was found: the system, the standard
    /// folders themselves, and the user's home and documents. `relative` is the path inside the
    /// allowed root ("/" when deleting for real).
    static func isNeverDeletable(_ relative: String, home: URL, root: String) -> Bool {
        let lowered = relative.lowercased()
        // In tests the home folder lives inside the fake root; in a sandbox run it's the real one.
        let fullHome = home.standardizedFileURL.path
        let homePath = (!root.isEmpty && fullHome.hasPrefix(root + "/") ? String(fullHome.dropFirst(root.count)) : fullHome).lowercased()
        if lowered.isEmpty || lowered == "/" { return true }
        let neverInside = ["/system", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/private/var/db", "/library/apple", "/dev", "/volumes",
                           homePath + "/documents", homePath + "/desktop", homePath + "/library/keychains", homePath + "/library/mobile documents"]
        if neverInside.contains(where: { lowered == $0 || lowered.hasPrefix($0 + "/") }) { return true }
        let never = ["/applications", "/users", "/users/shared", "/library", "/usr", "/usr/local", "/opt", "/private", "/private/var", "/private/var/folders", "/private/tmp",
                     "/var", "/tmp", "/etc", homePath, homePath + "/library", homePath + "/applications", homePath + "/downloads", homePath + "/.config",
                     homePath + "/.local", homePath + "/.local/share", homePath + "/.local/state", homePath + "/.local/bin", homePath + "/bin", homePath + "/.cache",
                     homePath + "/library/application support/steam", homePath + "/library/application support/steam/steamapps",
                     homePath + "/library/application support/steam/steamapps/common"]
        if never.contains(lowered) { return true }
        // The standard Library folders themselves (~/Library/Caches, /Library/LaunchDaemons, …).
        for base in [homePath + "/library", "/library"] where lowered.hasPrefix(base + "/") {
            let rest = lowered.dropFirst(base.count + 1).split(separator: "/")
            if rest.count == 1, Protection.standardLibraryFolders.contains(String(rest[0])) { return true }
        }
        return false
    }

    /// macOS's own links (/var → /private/var, /tmp → /private/tmp, /etc → /private/etc).
    private static func isSystemLink(_ path: String, resolved: String) -> Bool {
        ["/var", "/tmp", "/etc"].contains { path == $0 || path.hasPrefix($0 + "/") } && resolved == "/private" + path
    }
}
