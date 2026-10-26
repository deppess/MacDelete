import Darwin
import Foundation

/// Every location delete reads, so tests can point all of them at temporary folders and never
/// touch the real system.
public struct Roots: Sendable {
    /// The home folder of the user whose apps are being managed; under `sudo`, the invoking user's.
    public var home: URL
    public var applicationRoots: [ApplicationRoot]
    /// Homebrew prefixes that have a `Caskroom`.
    public var homebrewPrefixes: [URL]
    /// Installer-package receipts (`/var/db/receipts`).
    public var receipts: URL
    /// Whether to ask Spotlight for applications outside `applicationRoots` and for their sizes.
    public var spotlight: Bool
    /// The machine-wide Library (`/Library`).
    public var library: URL
    /// The user's per-user cache and temporary folders under /var/folders
    /// (`getconf DARWIN_USER_CACHE_DIR` / `DARWIN_USER_TEMP_DIR`). Code-signing copies live in
    /// the sibling `X` folder.
    public var userCache: URL?
    public var userTemp: URL?
    /// Homebrew's downloaded catalog (`~/Library/Caches/Homebrew/api`), for zap lists.
    public var homebrewCatalog: URL
    /// The commands delete runs; tests replace them with stub scripts.
    public var tools = Tools()

    /// The folder `library` lives in: "/" on a real system, the fake root in tests.
    public var systemRoot: String { library.standardizedFileURL.deletingLastPathComponent().path }

    public init(home: URL, applicationRoots: [ApplicationRoot], homebrewPrefixes: [URL] = [], receipts: URL, spotlight: Bool = false, library: URL? = nil, userCache: URL? = nil, userTemp: URL? = nil, homebrewCatalog: URL? = nil) {
        self.home = home
        self.applicationRoots = applicationRoots
        self.homebrewPrefixes = homebrewPrefixes
        self.receipts = receipts
        self.spotlight = spotlight
        self.library = library ?? URL(filePath: "/Library", directoryHint: .isDirectory)
        self.userCache = userCache
        self.userTemp = userTemp
        self.homebrewCatalog = homebrewCatalog ?? home.appending(path: "Library/Caches/Homebrew/api", directoryHint: .isDirectory)
    }

    public var codeSigningClones: URL? { userCache?.deletingLastPathComponent().appending(path: "X", directoryHint: .isDirectory) }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Roots {
        let home = userHome(environment: environment)
        return Roots(
            home: home,
            applicationRoots: [
                ApplicationRoot(url: URL(filePath: "/Applications", directoryHint: .isDirectory), classification: .user, required: true),
                ApplicationRoot(url: home.appending(path: "Applications", directoryHint: .isDirectory), classification: .user, required: false),
                ApplicationRoot(url: URL(filePath: "/System/Applications", directoryHint: .isDirectory), classification: .system, required: true),
                ApplicationRoot(url: URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory), classification: .system, required: true),
                ApplicationRoot(url: URL(filePath: "/Library/CoreServices", directoryHint: .isDirectory), classification: .system, required: false),
                // Steam games, also when Spotlight is off: `common/<game>/<…>/Game.app`.
                ApplicationRoot(url: home.appending(path: "Library/Application Support/Steam/steamapps/common", directoryHint: .isDirectory), classification: .user, required: false, maxDepth: 2, extensionlessBundles: true),
            ],
            homebrewPrefixes: homebrewPrefixes(environment: environment),
            receipts: URL(filePath: "/var/db/receipts", directoryHint: .isDirectory),
            spotlight: true,
            userCache: userFolder(_CS_DARWIN_USER_CACHE_DIR, letter: "C", environment: environment),
            userTemp: userFolder(_CS_DARWIN_USER_TEMP_DIR, letter: "T", environment: environment),
            homebrewCatalog: environment["HOMEBREW_CACHE"].flatMap { isSafeAbsolutePath($0) ? URL(filePath: $0, directoryHint: .isDirectory).appending(path: "api") : nil }
        )
    }

    /// The user's `/var/folders/<xx>/<hash>/<letter>` folder. Under sudo, confstr answers for
    /// root, so the invoking user's folder is found by its owner instead.
    static func userFolder(_ name: Int32, letter: String, environment: [String: String]) -> URL? {
        if geteuid() == 0, let uid = environment["SUDO_UID"].flatMap({ uid_t($0) }), uid != 0 {
            let base = URL(filePath: "/private/var/folders", directoryHint: .isDirectory)
            for bucket in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
                for hash in (try? FileManager.default.contentsOfDirectory(atPath: base.appending(path: bucket).path)) ?? [] {
                    let folder = base.appending(path: "\(bucket)/\(hash)", directoryHint: .isDirectory)
                    var info = stat()
                    if stat(folder.path, &info) == 0, info.st_uid == uid { return folder.appending(path: letter, directoryHint: .isDirectory) }
                }
            }
            return nil
        }
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath()
    }

    /// The managed user's home. Under `sudo`, HOME may already be root's, so the invoking user is
    /// looked up through SUDO_USER; otherwise the real user ID decides, not HOME, which anything
    /// can set.
    static func userHome(environment: [String: String]) -> URL {
        if geteuid() == 0, let user = environment["SUDO_USER"]?.nonEmpty, user != "root", let entry = getpwnam(user), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Prefixes holding a Caskroom, from the standard locations, HOMEBREW_PREFIX, and every
    /// `brew` on PATH (`<prefix>/bin/brew`). Found without running brew, which takes ~0.5 s.
    static func homebrewPrefixes(environment: [String: String]) -> [URL] {
        var candidates = ["/opt/homebrew", "/usr/local"]
        if let prefix = environment["HOMEBREW_PREFIX"], isSafeAbsolutePath(prefix) { candidates.append(prefix) }
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where isSafeAbsolutePath(entry) {
            let directory = URL(filePath: entry, directoryHint: .isDirectory).standardizedFileURL
            guard directory.lastPathComponent == "bin", isRegularExecutable(directory.appending(path: "brew").resolvingSymlinksInPath()) else { continue }
            candidates.append(directory.deletingLastPathComponent().path)
        }
        var seen = Set<String>()
        return candidates.compactMap { path in
            let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.appending(path: "Caskroom").path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(url.resolvingSymlinksInPath().path).inserted else { return nil }
            return url
        }
    }
}

public struct Tools: Sendable {
    public var pkgutil = URL(filePath: "/usr/sbin/pkgutil")
    public var lsbom = URL(filePath: "/usr/bin/lsbom")
    public var launchctl = URL(filePath: "/bin/launchctl")
    public var tccutil = URL(filePath: "/usr/bin/tccutil")
    public var systemextensionsctl = URL(filePath: "/usr/bin/systemextensionsctl")
    public var lsregister = URL(filePath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    /// Homebrew's `brew` in the cask's prefix is used when present; this is the fallback.
    public var brew: URL?

    public init() {}
}

public struct ApplicationRoot: Sendable {
    public var url: URL
    public var classification: AppClassification
    /// A required root that can't be read makes the scan incomplete.
    public var required: Bool
    /// How many folders deep to look for bundles; nil for no limit. Game folders can hold
    /// hundreds of thousands of files, so Steam's library is searched shallowly.
    public var maxDepth: Int?
    /// A folder directly inside the root that has its own `Contents/Info.plist` is an app even
    /// without the `.app` extension: some Steam games (Stardew Valley) ship their whole folder as
    /// the bundle.
    public var extensionlessBundles: Bool

    public init(url: URL, classification: AppClassification, required: Bool, maxDepth: Int? = nil, extensionlessBundles: Bool = false) {
        self.url = url
        self.classification = classification
        self.required = required
        self.maxDepth = maxDepth
        self.extensionlessBundles = extensionlessBundles
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
