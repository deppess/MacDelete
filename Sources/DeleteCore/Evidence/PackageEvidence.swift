import Foundation

/// What an app's installer packages put on disk.
///
/// A receipt's BOM lists every file and folder the package installed, including standard
/// folders like /Library/Application Support it merely passed through. The items that belong to
/// the package are the topmost entries below a standard folder. When another package lists that
/// same folder too (a vendor folder several products share), only this package's entries inside
/// it are taken.
enum PackageEvidence {
    struct Result {
        /// Receipts to forget: every item they installed is being deleted.
        var packages: [String] = []
        /// Receipts kept because the package also installed another app.
        var kept: [String] = []
        var findings: [Finding] = []
        var skipped: [Skipped] = []
    }

    /// The packages are those the inventory's receipts give the bundle (every package but
    /// Apple's, including those `pkgutil --file-info` misses: any not installed at "/").
    /// `pkgutil` (~25 ms) is asked only for Apple's apps (Xcode's App Store receipt), or when no
    /// receipt could be read.
    static func scan(application: InstalledApp, receipts: PackageReceipts, roots: Roots, otherApplicationPaths: Set<String>, runner: CommandRunner) -> Result {
        var packages = receipts.packages(for: application.path)
        if receipts.listings.isEmpty || application.bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true {
            for package in packagesInstalling(application.bundlePath, runner: runner, pkgutil: roots.tools.pkgutil)
            where !packages.contains(where: { $0.caseInsensitiveCompare(package) == .orderedSame }) {
                packages.append(package)
            }
        }
        guard !packages.isEmpty else { return Result() }
        var result = Result()

        // A folder another package lists too is shared (a vendor folder several products use).
        let own = Set(packages.map { $0.lowercased() })
        let isShared = { (path: String) in receipts.isListed(path, byOtherThan: own) }

        let bundle = application.bundlePath.lowercased() + "/"
        for package in packages {
            // Entries inside the app's bundle are covered by deleting the bundle (Xcode's
            // receipt lists 166,000 of them). Apple's receipts aren't in the index.
            let paths =
                receipts.listings[package].map { $0.filter { !$0.lowercased().hasPrefix(bundle) } }
                ?? listing(
                    receipt: roots.receipts.appending(path: "\(package).plist"), runner: runner, lsbom: roots.tools.lsbom,
                    excludingInside: application.bundlePath)
            let items = ownedItems(paths, isShared: isShared, root: roots.systemRoot).filter {
                FileManager.default.fileExists(atPath: $0) || isSymbolicLink($0)
            }
            // A package that also installed another app still on the Mac (a suite like DaVinci
            // Resolve's) owns its files together with that app: none of them, and not its
            // receipt, belong to this app alone.
            let otherApp = items.lazy.compactMap { item -> String? in
                let lowered = item.lowercased()
                return otherApplicationPaths.first {
                    let other = $0.lowercased(); return other == lowered || other.hasPrefix(lowered + "/") || lowered.hasPrefix(other + "/")
                }
            }.first
            if let otherApp {
                let name = URL(filePath: otherApp).lastPathComponent
                result.skipped.append(
                    Skipped(
                        path: roots.receipts.appending(path: "\(package).plist").path,
                        reason: "package \(package) also installed \(name), so its files stay while that app is installed"))
                result.kept.append(package)
                continue
            }
            for item in items where !Protection.isProtected(item, roots: roots) {
                result.findings.append(Finding(path: item, tier: .exact, reason: "installed by package \(package)"))
            }
            result.packages.append(package)
        }
        return result
    }

    /// Topmost entries below a standard folder, descending into any folder another package shares
    /// (`isShared` gets the lowercased path).
    static func ownedItems(_ paths: [String], isShared: (String) -> Bool, root: String = "/") -> [String] {
        // Standard folders are compared relative to the system root (a fake one in tests).
        let rootPrefix = root == "/" ? "" : root.lowercased()
        func isStandard(_ path: String) -> Bool {
            let lowered = path.lowercased()
            guard rootPrefix.isEmpty || lowered == rootPrefix || lowered.hasPrefix(rootPrefix + "/") else { return false }
            let relative = String(lowered.dropFirst(rootPrefix.count))
            return standardFolders.contains(relative.isEmpty ? "/" : relative)
        }
        // String operations only: a receipt can list hundreds of thousands of paths.
        func parent(_ path: String) -> String {
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
            return String(path[..<slash])
        }
        let unique = Set(paths)
        var children: [String: [String]] = [:]
        for path in unique { children[parent(path).lowercased(), default: []].append(path) }
        var owned: [String] = []
        var queue = unique.filter { isStandard(parent($0)) && !isStandard($0) }.sorted()
        while let path = queue.first {
            queue.removeFirst()
            if isShared(path.lowercased()) {
                queue += (children[path.lowercased()] ?? []).sorted()
            } else {
                owned.append(path)
            }
        }
        return owned.sorted()
    }

    /// Other packages whose every item is being deleted (one that installed only the app's
    /// launch daemon): their receipts are forgotten too. Only items outside the home and
    /// per-user temporary folders can be a package's (packages don't install into them).
    static func coveredPackages(findings: [Finding], application: InstalledApp, excluding: [String], receipts: PackageReceipts, roots: Roots) -> [String] {
        let skipped = ([roots.home] + [roots.userCache, roots.userTemp, roots.codeSigningClones].compactMap { $0 }).map {
            $0.standardizedFileURL.path.lowercased() + "/"
        }
        let bundles = Set([application.path, application.bundlePath].map { $0.lowercased() })
        let deleted = findings.filter { $0.tier == .exact }.map { $0.path.lowercased() }
        let candidates = Set(deleted.filter { path in !bundles.contains(path) && !skipped.contains { path.hasPrefix($0) } })
        guard !candidates.isEmpty else { return [] }
        func isDeleted(_ path: String) -> Bool {
            let lowered = path.lowercased()
            return deleted.contains { lowered == $0 || lowered.hasPrefix($0 + "/") }
        }
        let excluded = Set(excluding.map { $0.lowercased() })
        return receipts.listings.keys.sorted().filter { package in
            guard !excluded.contains(package.lowercased()), let paths = receipts.listings[package],
                receipts.lowercasedListings[package]?.isDisjoint(with: candidates) == false
            else { return false }
            let items = ownedItems(paths, isShared: { _ in false }, root: roots.systemRoot).filter {
                FileManager.default.fileExists(atPath: $0) || isSymbolicLink($0)
            }
            return !items.isEmpty && items.allSatisfy(isDeleted)
        }
    }

    /// `pkgutil --file-info` names every package that installed the bundle, Apple's App Store
    /// receipts (Xcode) included.
    static func packagesInstalling(_ path: String, runner: CommandRunner, pkgutil: URL) -> [String] {
        guard
            let result = try? runner.run(
                executable: pkgutil, arguments: ["--file-info", path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin", "LC_ALL": "C"], timeout: 10,
                outputLimit: 1_048_576),
            result.status == 0
        else { return [] }
        var packages: [String] = []
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") where line.hasPrefix("pkgid: ") {
            let identifier = line.dropFirst("pkgid: ".count).trimmingCharacters(in: .whitespaces)
            if EmbeddedBundles.isReverseDNS(identifier), !packages.contains(identifier) { packages.append(identifier) }
        }
        return packages
    }

    /// Absolute paths listed in a receipt that isn't in the index (Apple's).
    static func listing(receipt plist: URL, runner: CommandRunner, lsbom: URL, excludingInside excluded: String? = nil) -> [String] {
        let bom = plist.deletingPathExtension().appendingPathExtension("bom")
        guard FileManager.default.fileExists(atPath: bom.path) else { return [] }
        let prefix = SmallFile.plist(atPath: plist.path)?["InstallPrefixPath"] as? String ?? "/"
        return PackageReceipts.listing(bom: bom, installPrefix: prefix, runner: runner, lsbom: lsbom, excludingInside: excluded)
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Folders packages install into but never own. Lowercased.
    static let standardFolders: Set<String> = Set(
        [
            "/", "/Applications", "/Applications/Utilities", "/Users", "/Users/Shared", "/opt", "/private", "/private/etc", "/private/var", "/private/tmp",
            "/etc", "/var", "/tmp",
            "/usr", "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/include", "/usr/local/share", "/usr/local/etc",
            "/usr/local/libexec",
            "/usr/local/share/man", "/usr/local/share/man/man1", "/usr/local/share/man/man5", "/usr/local/share/man/man8", "/usr/local/share/doc",
            "/Library", "/Library/Application Support", "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/Components",
            "/Library/Audio/Plug-Ins/VST",
            "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/CLAP", "/Library/Audio/Plug-Ins/ARA",
            "/Library/Audio/MIDI Drivers",
            "/Library/Audio/MIDI Devices", "/Library/Audio/Sounds", "/Library/Audio/Apple Loops", "/Library/Application Support/Avid",
            "/Library/Application Support/Avid/Audio",
            "/Library/Application Support/Avid/Audio/Plug-Ins", "/Library/Application Support/Digidesign", "/Library/Application Support/Digidesign/Plug-Ins",
            "/Library/Automator", "/Library/Bundles", "/Library/Caches", "/Library/ColorPickers", "/Library/ColorSync", "/Library/ColorSync/Profiles",
            "/Library/Components",
            "/Library/Contextual Menu Items", "/Library/CoreMediaIO", "/Library/CoreMediaIO/Plug-Ins", "/Library/CoreMediaIO/Plug-Ins/DAL",
            "/Library/Desktop Pictures",
            "/Library/Dictionaries", "/Library/DirectoryServices", "/Library/DirectoryServices/PlugIns", "/Library/Documentation", "/Library/DriverExtensions",
            "/Library/Extensions",
            "/Library/Filesystems", "/Library/Fonts", "/Library/Frameworks", "/Library/Graphics", "/Library/Image Capture", "/Library/Image Capture/Devices",
            "/Library/Input Methods", "/Library/Internet Plug-Ins", "/Library/Java", "/Library/Java/Extensions", "/Library/Java/JavaVirtualMachines",
            "/Library/Keyboard Layouts",
            "/Library/Keychains", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Logs", "/Library/Mail", "/Library/Mail/Bundles",
            "/Library/PDF Services",
            "/Library/Perl", "/Library/PreferencePanes", "/Library/Preferences", "/Library/Printers", "/Library/PrivilegedHelperTools", "/Library/Python",
            "/Library/QuickLook",
            "/Library/Receipts", "/Library/Ruby", "/Library/Screen Savers", "/Library/Scripts", "/Library/Security", "/Library/Services", "/Library/Spotlight",
            "/Library/StartupItems", "/Library/SystemExtensions", "/Library/User Pictures", "/Library/Video", "/Library/Video/Plug-Ins", "/Library/WebServer",
            "/Library/Widgets",
            "/Library/Workflows", "/Library/Workflows/Applications", "/Library/Developer"
        ].map { $0.lowercased() })
}
