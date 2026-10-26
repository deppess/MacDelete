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

    /// The Caskroom folder an app's executable links into when Homebrew installed it as a link.
    public var caskroomPath: String { "\(prefix)/Caskroom/\(token)/" }
}

/// Reads install receipts straight from the Caskroom. `brew info --installed --json=v2` gives the
/// same answer but takes ~0.7 s; these files take a few milliseconds.
public enum Caskroom {
    public static func installedCasks(prefixes: [URL], home: URL) -> [InstalledCask] {
        prefixes.flatMap { prefix -> [InstalledCask] in
            let caskroom = prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
            guard let tokens = try? FileManager.default.contentsOfDirectory(atPath: caskroom.path) else { return [] }
            return tokens.sorted().compactMap { token in
                guard !token.hasPrefix(".") else { return nil }
                return cask(token: token, prefix: prefix, home: home)
            }
        }
    }

    static func cask(token: String, prefix: URL, home: URL) -> InstalledCask? {
        let metadata = prefix.appending(path: "Caskroom/\(token)/.metadata", directoryHint: .isDirectory)
        guard let receipt = readJSON(metadata.appending(path: "INSTALL_RECEIPT.json")) as? [String: Any] else { return nil }
        let config = readJSON(metadata.appending(path: "config.json")) as? [String: Any]
        let configuredAppdir = ((config?["default"] as? [String: Any])?["appdir"] as? String) ?? ((config?["explicit"] as? [String: Any])?["appdir"] as? String)
        let appdir = expand(configuredAppdir ?? "/Applications", home: home, relativeTo: "/Applications")

        var appPaths: [String] = []
        var suitePaths: [String] = []
        var packagePatterns: [String] = []
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
                        if let single = directive["pkgutil"] as? String { packagePatterns.append(single) }
                        packagePatterns += directive["pkgutil"] as? [String] ?? []
                    }
                default: continue
                }
            }
        }
        let version = (receipt["source"] as? [String: Any])?["version"] as? String
        return InstalledCask(token: token, prefix: prefix.path, version: version, appPaths: appPaths, suitePaths: suitePaths, packagePatterns: packagePatterns)
    }

    /// Whether a package identifier matches a cask's `pkgutil:` entry, which Homebrew treats as a
    /// regular expression matched against the whole identifier.
    static func package(_ identifier: String, matches pattern: String) -> Bool {
        if identifier == pattern { return true }
        guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return false }
        return expression.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)) != nil
    }

    private static func expand(_ path: String, home: URL, relativeTo base: String) -> String {
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))).standardizedFileURL.path }
        if path.hasPrefix("/") { return URL(filePath: path).standardizedFileURL.path }
        return URL(filePath: base, directoryHint: .isDirectory).appending(path: path).standardizedFileURL.path
    }

    private static func readJSON(_ url: URL) -> Any? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? .max) <= 4 * 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
