import Foundation

public enum MatchResult: Sendable {
    case found(InstalledApp)
    case ambiguous([InstalledApp])
    /// Only a name prefix matched, and prefixes weren't allowed.
    case prefixOnly(InstalledApp)
    case notFound
}

/// Resolves what the user typed: a path, a bundle identifier, or a name, case-insensitively.
/// An exact name or identifier wins; otherwise a unique name prefix is enough.
public enum AppMatcher {
    /// `allowPrefix` is false for `-y`: deleting without a question needs the app's full name,
    /// identifier or path, so a short prefix can't pick an app nobody looked at.
    public static func match(_ query: String, in applications: [InstalledApp], home: URL, allowPrefix: Bool = true) -> MatchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        if trimmed.contains("/") { return matchPath(trimmed, in: applications, home: home) }

        let lowered = trimmed.lowercased()
        let withoutExtension = lowered.hasSuffix(".app") ? String(lowered.dropLast(4)) : lowered
        var exact = applications.filter { application in
            application.bundleIdentifier?.lowercased() == lowered || names(of: application).contains(withoutExtension)
        }
        // An installed app outranks a same-named copy elsewhere (a build product, a mounted DMG),
        // and a Steam game outranks its desktop shortcut, which is deleted with it.
        if exact.count > 1, exact.contains(where: { $0.classification == .user }) { exact.removeAll { $0.classification != .user } }
        if exact.count > 1, exact.contains(where: { !$0.isSteamShortcut }) { exact.removeAll(where: \.isSteamShortcut) }
        if !exact.isEmpty { return exact.count == 1 ? .found(exact[0]) : .ambiguous(exact) }

        // Prefixes consider only apps a user would mean; a prefix landing on a helper or a macOS
        // component would be surprising.
        var prefixed = applications.filter { application in
            application.classification == .user && names(of: application).contains { $0.hasPrefix(withoutExtension) }
        }
        prefixed = Inventory.foldingSteamShortcuts(prefixed)
        switch prefixed.count {
        case 0: return .notFound
        case 1: return allowPrefix ? .found(prefixed[0]) : .prefixOnly(prefixed[0])
        default: return .ambiguous(prefixed)
        }
    }

    private static func names(of application: InstalledApp) -> [String] {
        ([application.name] + application.alternateNames).map { $0.lowercased() }
    }

    /// A path: the scanned app at that location (or the same bundle under another spelling), or
    /// a bundle the scan didn't list, read directly.
    private static func matchPath(_ query: String, in applications: [InstalledApp], home: URL) -> MatchResult {
        let expanded = query == "~" ? home.path : query.hasPrefix("~/") ? home.appending(path: String(query.dropFirst(2))).path : query
        let absolute =
            expanded.hasPrefix("/")
            ? URL(filePath: expanded) : URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory).appending(path: expanded)
        let url = absolute.standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        if let application = applications.first(where: { $0.path == url.path || $0.bundlePath == resolved || $0.path == resolved }) {
            return .found(application)
        }
        let target = identity(url.path)
        if let target, let application = applications.first(where: { identity($0.bundlePath) == target }) { return .found(application) }
        guard url.pathExtension.lowercased() == "app", isPlausibleApplicationBundle(url) else { return .notFound }
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let bundle = isLink ? url.resolvingSymlinksInPath() : url
        let classification = AppScanner.classification(forPath: bundle.path, home: home.path)
        guard let application = try? AppScanner.application(at: url, bundle: bundle, classification: classification) else { return .notFound }
        return .found(application)
    }

    private static func identity(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}
