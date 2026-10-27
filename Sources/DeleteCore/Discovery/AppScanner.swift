import Foundation

/// Whether `url` is plausibly a top-level installed application: it has a `Contents` directory
/// (or is an iOS app wrapper), and it isn't nested inside another bundle. A folder merely named
/// "*.app" is not a bundle (the App Sandbox creates empty "<extension id>.app" script folders), and
/// helpers, XPC services and frameworks inside another bundle belong to that bundle.
func isPlausibleApplicationBundle(_ url: URL) -> Bool {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.appending(path: "Contents").path) || isIOSWrapper(url) else { return false }
    let nestedBundleExtensions: Set<String> = ["app", "framework", "bundle", "xpc", "appex", "plugin", "kext", "systemextension"]
    var ancestor = url.deletingLastPathComponent()
    while ancestor.pathComponents.count > 1 {
        if nestedBundleExtensions.contains(ancestor.pathExtension.lowercased()) { return false }
        ancestor = ancestor.deletingLastPathComponent()
    }
    return true
}

/// An iPhone or iPad app installed on Apple Silicon: no `Contents`, but a `Wrapper` folder and a
/// `WrappedBundle` link to the iOS bundle inside it.
func isIOSWrapper(_ url: URL) -> Bool {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.appending(path: "Wrapper").path, isDirectory: &isDirectory) && isDirectory.boolValue
        && (try? url.appending(path: "WrappedBundle").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}

public struct ScanResult: Sendable {
    public var applications: [InstalledApp]
    /// Allocated sizes Spotlight reported, by path.
    public var spotlightSizes: [String: Int64]
    public var warnings: [String]
    /// False when a required root or a bundle couldn't be read.
    public var complete: Bool
}

/// Finds every application bundle: a walk of the application roots, plus a Spotlight query run
/// concurrently with it for bundles elsewhere (and their sizes). Adapted from Sift's
/// NativeApplicationProvider.
public struct AppScanner: Sendable {
    public let roots: Roots
    private let runner: CommandRunner

    public init(roots: Roots, runner: CommandRunner = CommandRunner()) {
        self.roots = roots
        self.runner = runner
    }

    public func scan() -> ScanResult {
        var warnings: [String] = []
        var complete = true
        // `url` is the path recorded (which may be a symlink, e.g. /Applications/Safari.app);
        // `bundle` is the real bundle directory its metadata is read from.
        var candidates: [(url: URL, bundle: URL, classification: AppClassification)] = []
        var seenCandidates = Set<String>()
        // Firmlinks (/Applications aliasing /System/Volumes/Data/Applications) are not symlinks, so
        // path resolution can't unify the two spellings the walk and Spotlight may report for the
        // same bundle. Device+inode identity catches that.
        var seenIdentities = Set<BundleIdentity>()
        let scanner = self
        let spotlight = roots.spotlight ? Concurrent { Result { try scanner.spotlightApplications() } } : nil

        for root in roots.applicationRoots {
            let normalizedRoot = root.url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if root.required {
                    warnings.append("Application folder is unavailable: \(normalizedRoot.path)")
                    complete = false
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                // Not .skipsHiddenFiles: that also skips entries carrying the BSD hidden flag, which
                // macOS sets on /Applications/Safari.app. Dot-files are skipped by name below.
                options: [],
                errorHandler: { url, error in
                    warnings.append("Unable to read \(url.path): \(error.localizedDescription)")
                    complete = false
                    return true
                }
            ) else {
                warnings.append("Unable to read \(normalizedRoot.path).")
                complete = false
                continue
            }
            for case let candidate as URL in enumerator {
                if candidate.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
                if let maxDepth = root.maxDepth, enumerator.level > maxDepth + 1 { enumerator.skipDescendants(); continue }
                // Symlinked directories are never descended into; only a symlink that is itself an
                // application bundle (macOS ships /Applications/Safari.app this way) is followed.
                let isFolderBundle = root.extensionlessBundles && enumerator.level == 1 && candidate.pathExtension.lowercased() != "app"
                    && FileManager.default.fileExists(atPath: candidate.appending(path: "Contents/Info.plist").path)
                guard candidate.pathExtension.lowercased() == "app" || isFolderBundle else { continue }
                enumerator.skipDescendants()
                let isSymbolicLink = (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                let normalized = candidate.standardizedFileURL
                guard isContained(normalized, in: normalizedRoot), isPlausibleApplicationBundle(normalized),
                      let bundle = resolvedBundle(normalized, isSymbolicLink: isSymbolicLink),
                      seenIdentities.insert(fileIdentity(bundle) ?? BundleIdentity(path: bundle.path)).inserted else { continue }
                // A linked bundle takes its classification from where it really lives, so Safari's
                // Cryptex link in /Applications is still part of macOS.
                let classification = isSymbolicLink ? classify(bundle) : root.classification
                if seenCandidates.insert(normalized.path).inserted { candidates.append((normalized, bundle, classification)) }
            }
        }

        var spotlightSizes: [String: Int64] = [:]
        if let spotlight {
            do {
                for (path, size) in try spotlight.value.get() {
                    let rawCandidate = URL(filePath: path).standardizedFileURL
                    let isSymbolicLink = (try? rawCandidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                    // Directory components are resolved, but a candidate that is itself a link keeps
                    // its own name, matching the walk.
                    let candidate = isSymbolicLink ? rawCandidate.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: rawCandidate.lastPathComponent) : rawCandidate.resolvingSymlinksInPath()
                    if let size { spotlightSizes[candidate.path] = size }
                    guard candidate.pathExtension.lowercased() == "app", isPlausibleApplicationBundle(candidate),
                          let bundle = resolvedBundle(candidate, isSymbolicLink: isSymbolicLink),
                          seenIdentities.insert(fileIdentity(bundle) ?? BundleIdentity(path: bundle.path)).inserted,
                          seenCandidates.insert(candidate.path).inserted else { continue }
                    candidates.append((candidate, bundle, classify(isSymbolicLink ? bundle : candidate)))
                }
            } catch {
                // Spotlight can be disabled or exclude folders; the walk of the roots still stands.
                warnings.append("Spotlight application search: \(error.localizedDescription)")
            }
        }

        // Each bundle's metadata is read independently, so they're read across all cores.
        let found = candidates
        let results = UnsafeResults<Result<InstalledApp?, Error>>(count: found.count)
        DispatchQueue.concurrentPerform(iterations: found.count) { index in
            let candidate = found[index]
            results[index] = Result { try Self.application(at: candidate.url, bundle: candidate.bundle, classification: candidate.classification) }
        }
        var applications: [InstalledApp] = []
        for (candidate, result) in zip(found, results.values) {
            switch result {
            case var .success(application?):
                application.size = spotlightSizes[candidate.url.path] ?? spotlightSizes[candidate.bundle.path]
                applications.append(application)
            case .success(nil): break
            case let .failure(error):
                warnings.append("Unable to read \(candidate.url.lastPathComponent): \(error.localizedDescription)")
                complete = false
            }
        }
        return ScanResult(applications: applications.sorted { $0.path < $1.path }, spotlightSizes: spotlightSizes, warnings: warnings, complete: complete)
    }

    /// Reads one bundle. Also used for a path given on the command line that the scan didn't find.
    static func application(at url: URL, bundle: URL, classification: AppClassification) throws -> InstalledApp? {
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let isIOS = isIOSWrapper(bundle)
        let plistURL = isIOS ? bundle.appending(path: "WrappedBundle").resolvingSymlinksInPath().appending(path: "Info.plist") : bundle.appending(path: "Contents/Info.plist")
        let plistValues = try plistURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard plistValues.isRegularFile == true, plistValues.isSymbolicLink != true else { throw ScanError.invalidMetadata }
        guard (plistValues.fileSize ?? 0) <= 1_048_576 else { throw ScanError.metadataTooLarge }
        let data = try Data(contentsOf: plistURL, options: [.mappedIfSafe])
        guard let metadata = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw ScanError.invalidMetadata }

        // Only ".app" is an extension here: a game folder named "Foo 1.5" keeps its whole name.
        let name = url.pathExtension.lowercased() == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        var alternateNames: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = visibleName(metadata[key]), value.caseInsensitiveCompare(name) != .orderedSame, !alternateNames.contains(value) { alternateNames.append(value) }
        }
        let bundleIdentifier = (metadata["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let executable = (metadata["CFBundleExecutable"] as? String)?.nonEmpty.flatMap { $0.contains("/") ? nil : $0 }
        let steamShortcut = bundleIdentifier == nil && !isIOS && isSteamShortcut(bundle, executable: executable)

        var linkTargets: [String] = []
        if bundle.path != url.path { linkTargets.append(bundle.path) }
        if let executable, !isIOS {
            let executableURL = bundle.appending(path: "Contents/MacOS").appending(path: executable)
            if (try? executableURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { linkTargets.append(executableURL.resolvingSymlinksInPath().path) }
        }
        let hasReceipt = FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/_MASReceipt/receipt").path)
        return InstalledApp(
            path: url.path, bundlePath: bundle.path, name: name, bundleIdentifier: bundleIdentifier, alternateNames: alternateNames,
            // The marketing version, else the build version (Steam and some utilities set only that).
            version: (metadata["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? (metadata["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            executableName: executable, classification: classification, source: .download, size: nil, linkTargets: linkTargets,
            hasAppStoreReceipt: hasReceipt || isIOS, isIOSApp: isIOS, isSteamShortcut: steamShortcut
        )
    }

    /// Some bundles (several CoreServices UI agents among them) carry a name made only of
    /// invisible characters such as U+200E; those don't count as a name.
    private static func visibleName(_ value: Any?) -> String? {
        guard let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let isVisible = name.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint && $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }
        return isVisible ? name : nil
    }

    /// Steam's "Create desktop shortcut" writes a bundle with no identifier whose executable is a
    /// tiny generated script running `open steam://run/<id>`. The script is read, never executed.
    private static func isSteamShortcut(_ bundle: URL, executable: String?) -> Bool {
        guard let executable else { return false }
        let script = bundle.appending(path: "Contents/MacOS").appending(path: executable)
        guard let contents = SmallFile.text(atPath: script.path, limit: 4_096) else { return false }
        return contents.contains("steam://run/")
    }

    /// The real bundle directory for a candidate: the candidate itself, or, for a symlinked
    /// candidate, its destination when that is a top-level application bundle.
    private func resolvedBundle(_ url: URL, isSymbolicLink: Bool) -> URL? {
        guard isSymbolicLink else { return url }
        let destination = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard destination.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue,
              isPlausibleApplicationBundle(destination) else { return nil }
        return destination
    }

    /// Every application bundle Spotlight knows, with its allocated size when indexed. Output
    /// records are `<path>   kMDItemPhysicalSize = <bytes or (null)>`, NUL-separated.
    private func spotlightApplications() throws -> [(path: String, size: Int64?)] {
        let result = try runner.run(executable: URL(filePath: "/usr/bin/mdfind"), arguments: ["-0", "-onlyin", "/", "kMDItemContentType == \"com.apple.application-bundle\"c", "-attr", "kMDItemPhysicalSize"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 30, outputLimit: 32 * 1_024 * 1_024)
        guard result.status == 0 else { throw ScanError.spotlightFailed }
        let separator = "   kMDItemPhysicalSize = "
        return result.stdout.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            let line = String(decoding: record, as: UTF8.self)
            guard let range = line.range(of: separator, options: .backwards) else { return line.hasPrefix("/") ? (line, nil) : nil }
            return (String(line[..<range.lowerBound]), Int64(line[range.upperBound...]))
        }
    }

    /// The classification of the deepest application root holding `url`, so a linked bundle is
    /// classified by where it really lives; outside every root, by its location.
    private func classify(_ url: URL) -> AppClassification {
        roots.applicationRoots
            .map { (root: $0, url: $0.url.standardizedFileURL.resolvingSymlinksInPath()) }
            .filter { isContained(url, in: $0.url) }
            .max { $0.url.path.count < $1.url.path.count }?.root.classification
            ?? Self.classification(forPath: url.path, home: roots.home.path)
    }

    /// Classification for a bundle outside every application root.
    static func classification(forPath path: String, home: String) -> AppClassification {
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/Library/CoreServices/") { return .system }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .user }
        if path.range(of: "/steamapps/common/", options: .caseInsensitive) != nil { return .user }
        // An external drive's own Applications folder (/Volumes/X/Applications/App.app).
        let parts = path.split(separator: "/")
        if parts.count >= 4, parts[0] == "Volumes", parts[2] == "Applications" { return .user }
        return .auxiliary
    }

    private func fileIdentity(_ url: URL) -> BundleIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return BundleIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}

private struct BundleIdentity: Hashable {
    let device: Int32
    let inode: UInt64
    let path: String?

    init(device: Int32, inode: UInt64) { (self.device, self.inode, self.path) = (device, inode, nil) }
    /// Fallback identity when stat fails; distinct per path, so it never merges two bundles.
    init(path: String) { (self.device, self.inode, self.path) = (0, 0, path) }
}

public enum ScanError: LocalizedError {
    case metadataTooLarge, invalidMetadata, spotlightFailed
    public var errorDescription: String? {
        switch self {
        case .metadataTooLarge: "Bundle metadata exceeds the 1 MiB limit."
        case .invalidMetadata: "Bundle metadata is not a property-list dictionary."
        case .spotlightFailed: "mdfind returned a nonzero status."
        }
    }
}
