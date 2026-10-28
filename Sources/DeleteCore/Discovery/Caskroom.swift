import Foundation

/// One installed Homebrew cask, read from `<prefix>/Caskroom/<token>/.metadata`.
public struct InstalledCask: Sendable, Equatable {
    public var token: String
    public var prefix: String
    public var version: String?
    /// Absolute paths of the cask's `app` artifacts.
    public var appPaths: [String]
    /// Folders of the cask's `suite` artifacts; every app inside belongs to the cask.
    public var suitePaths: [String]
    /// Package identifiers (or patterns) from `uninstall pkgutil:`; apps those packages installed
    /// belong to the cask.
    public var packagePatterns: [String]
    /// Targets outside the app bundle that Homebrew removes as ordinary artifacts (currently
    /// command-line binaries and wrappers). They must be concrete findings in delete's plan.
    public var removalArtifactPaths: [String] = []
    /// Exact paths from Homebrew's declarative `uninstall delete:` directive. Scripts and glob
    /// patterns are deliberately not accepted here.
    public var uninstallDeletePaths: [String] = []
    /// Exact folders from declarative `uninstall rmdir:`. They are removed only once empty.
    public var uninstallEmptyFolders: [String] = []
    /// Labels from declarative `uninstall launchctl:` directives. They are usable only when
    /// discovery resolves each one to a concrete LaunchAgent/LaunchDaemon plist.
    public var launchctlLabels: [String] = []
    /// Bundle identifiers from declarative `uninstall quit:` directives. These may be modeled only
    /// when they are identities discovered in the app being removed.
    public var quitIdentifiers: [String] = []
    /// Artifact/directive kinds that this version of delete cannot model exactly. Such a cask is
    /// still listed and attributed, but cannot be removed behind a plan that omits its effects.
    public var unsupportedUninstallArtifacts: [String] = []

    public var mayReplicateUninstall: Bool { unsupportedUninstallArtifacts.isEmpty }

    /// The Caskroom folder an app's executable links into when Homebrew installed it as a link.
    public var caskroomPath: String { "\(prefix)/Caskroom/\(token)/" }
}

/// Reads install receipts straight from the Caskroom. `brew info --installed --json=v2` gives the
/// same answer but takes ~0.7 s; these files take a few milliseconds.
public enum Caskroom {
    /// Installed-cask metadata is ownership evidence.  A malformed receipt must not look like a
    /// cask that simply has no artifacts: that could make an app or a package appear unshared.
    public struct Scan: Sendable {
        public var casks: [InstalledCask]
        public var warnings: [String]
        public var complete: Bool { warnings.isEmpty }
    }

    public static func installedCasks(prefixes: [URL], home: URL) -> [InstalledCask] {
        scan(prefixes: prefixes, home: home).casks
    }

    public static func scan(prefixes: [URL], home: URL) -> Scan {
        var casks: [InstalledCask] = []
        var warnings: [String] = []
        for prefix in prefixes {
            let caskroom = prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: caskroom.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                warnings.append("Homebrew Caskroom is not a folder: \(caskroom.path)")
                continue
            }
            switch Directory.names(atPath: caskroom.path) {
            case let .failure(error):
                warnings.append("Unable to read Homebrew Caskroom \(caskroom.path): \(String(cString: strerror(error.code)))")
            case let .success(tokens):
                for token in tokens.sorted() where !token.hasPrefix(".") {
                    let parsed = cask(token: token, prefix: prefix, home: home)
                    if let cask = parsed.cask { casks.append(cask) }
                    if let warning = parsed.warning { warnings.append(warning) }
                }
            }
        }
        return Scan(casks: casks, warnings: warnings)
    }

    private static func cask(token: String, prefix: URL, home: URL) -> (cask: InstalledCask?, warning: String?) {
        let metadata = prefix.appending(path: "Caskroom/\(token)/.metadata", directoryHint: .isDirectory)
        let receiptPath = metadata.appending(path: "INSTALL_RECEIPT.json")
        guard let receipt = readJSON(receiptPath) as? [String: Any] else {
            return (nil, "Unable to read Homebrew receipt for \(token): \(receiptPath.path)")
        }
        let configPath = metadata.appending(path: "config.json")
        let config: [String: Any]?
        if FileManager.default.fileExists(atPath: configPath.path) {
            guard let parsed = readJSON(configPath) as? [String: Any] else {
                return (nil, "Unable to read Homebrew configuration for \(token): \(configPath.path)")
            }
            config = parsed
        } else {
            config = nil
        }
        let configuredAppdir = ((config?["default"] as? [String: Any])?["appdir"] as? String) ?? ((config?["explicit"] as? [String: Any])?["appdir"] as? String)
        let appdir = expand(configuredAppdir ?? "/Applications", home: home, relativeTo: "/Applications")

        var appPaths: [String] = []
        var suitePaths: [String] = []
        var packagePatterns: [String] = []
        var removalArtifactPaths: [String] = []
        var uninstallDeletePaths: [String] = []
        var uninstallEmptyFolders: [String] = []
        var launchctlLabels: [String] = []
        var quitIdentifiers: [String] = []
        var unsupported = Set<String>()
        for stanza in receipt["uninstall_artifacts"] as? [[String: Any]] ?? [] {
            for (key, value) in stanza {
                switch key {
                case "app", "suite":
                    // `["Foo.app"]` or `["Foo.app", {"target": "Bar.app"}]`.
                    guard let arguments = value as? [Any], let source = arguments.first as? String else { continue }
                    let target = (arguments.dropFirst().first as? [String: Any])?["target"] as? String
                    let path = expand(target ?? URL(filePath: source).lastPathComponent, home: home, relativeTo: appdir)
                    if key == "app" { appPaths.append(path) } else { suitePaths.append(path) }
                case "uninstall":
                    for directive in value as? [[String: Any]] ?? [] {
                        for (directiveKey, directiveValue) in directive {
                            switch directiveKey {
                            case "delete", "rmdir":
                                guard let paths = exactPaths(directiveValue, home: home) else {
                                    unsupported.insert("uninstall \(directiveKey)")
                                    continue
                                }
                                if directiveKey == "delete" { uninstallDeletePaths += paths }
                                else { uninstallEmptyFolders += paths }
                            case "pkgutil":
                                let patterns: [String]
                                if let single = directiveValue as? String { patterns = [single] }
                                else if let list = directiveValue as? [String] { patterns = list }
                                else { unsupported.insert("uninstall pkgutil"); continue }
                                guard patterns.allSatisfy(safePackagePattern) else {
                                    unsupported.insert("uninstall pkgutil")
                                    continue
                                }
                                packagePatterns += patterns
                            case "launchctl":
                                guard let labels = launchLabels(directiveValue) else {
                                    unsupported.insert("uninstall launchctl")
                                    continue
                                }
                                launchctlLabels += labels
                            case "quit":
                                guard let identifiers = launchLabels(directiveValue) else {
                                    unsupported.insert("uninstall quit")
                                    continue
                                }
                                quitIdentifiers += identifiers
                            default:
                                unsupported.insert("uninstall \(directiveKey)")
                            }
                        }
                    }
                case "binary", "command_wrapper":
                    // Both artifacts install their target into `<prefix>/bin`. A `binary` may
                    // rename its target; a command wrapper's options have no `target`, so its
                    // declared command name is the target.
                    guard let arguments = value as? [Any], let source = arguments.first as? String else {
                        unsupported.insert(key)
                        continue
                    }
                    let target = (arguments.dropFirst().first as? [String: Any])?["target"] as? String
                    let name = URL(filePath: target ?? source).lastPathComponent
                    guard !name.isEmpty, name != ".", name != ".." else { unsupported.insert(key); continue }
                    removalArtifactPaths.append(prefix.appending(path: "bin/\(name)").path)
                case "zap": continue // delete models zap paths itself.
                default: unsupported.insert(key)
                }
            }
        }
        let version = (receipt["source"] as? [String: Any])?["version"] as? String
        return (InstalledCask(token: token, prefix: prefix.path, version: version, appPaths: appPaths, suitePaths: suitePaths, packagePatterns: packagePatterns,
                              removalArtifactPaths: Array(Set(removalArtifactPaths)).sorted(), uninstallDeletePaths: Array(Set(uninstallDeletePaths)).sorted(),
                              uninstallEmptyFolders: Array(Set(uninstallEmptyFolders)).sorted(), launchctlLabels: Array(Set(launchctlLabels)).sorted(),
                              quitIdentifiers: Array(Set(quitIdentifiers)).sorted(),
                              unsupportedUninstallArtifacts: unsupported.sorted()), nil)
    }

    /// Whether a package identifier matches one of delete's deliberately narrow `pkgutil:` forms:
    /// an exact identifier, or a literal identifier-component prefix ending in `.*`.
    static func package(_ identifier: String, matches pattern: String) -> Bool {
        if identifier == pattern { return true }
        guard pattern.hasSuffix(".*") else { return false }
        let prefix = String(pattern.dropLast(1))
        return identifier.hasPrefix(prefix)
    }

    private static func expand(_ path: String, home: URL, relativeTo base: String) -> String {
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))).standardizedFileURL.path }
        if path.hasPrefix("/") { return URL(filePath: path).standardizedFileURL.path }
        return URL(filePath: base, directoryHint: .isDirectory).appending(path: path).standardizedFileURL.path
    }

    /// Homebrew's `delete:` and `rmdir:` are accepted only as fixed, absolute (or home-relative)
    /// locations.  This avoids importing Homebrew's shell/glob semantics into a deletion tool.
    private static func exactPaths(_ value: Any, home: URL) -> [String]? {
        let values: [String]
        if let single = value as? String { values = [single] }
        else if let list = value as? [String] { values = list }
        else { return nil }
        var paths: [String] = []
        for value in values {
            guard (value.hasPrefix("/") || value.hasPrefix("~/")),
                  !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
                  !value.contains(where: { "*?[]{}$`\\".contains($0) }) else { return nil }
            let path = expand(value, home: home, relativeTo: "/")
            guard path != "/" else { return nil }
            paths.append(path)
        }
        return paths
    }

    private static func launchLabels(_ value: Any) -> [String]? {
        let labels: [String]
        if let single = value as? String { labels = [single] }
        else if let list = value as? [String] { labels = list }
        else { return nil }
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } }) else { return nil }
        return labels
    }

    /// Homebrew accepts regular expressions for pkgutil, but receipt forgetting must never match
    /// arbitrary system records. Accept an exact identifier or a terminal `.*` after at least
    /// three literal identifier components (for example `com.vendor.product.*`).
    private static func safePackagePattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isLetter || $0.isNumber || "._-*".contains($0) }) else { return false }
        guard pattern.contains("*") else { return true }
        guard pattern.hasSuffix(".*"), pattern.dropLast(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return false }
        return pattern.dropLast(2).split(separator: ".", omittingEmptySubsequences: true).count >= 3
    }

    private static func readJSON(_ url: URL) -> Any? {
        SmallFile.data(atPath: url.path, limit: 4 * 1_048_576).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
