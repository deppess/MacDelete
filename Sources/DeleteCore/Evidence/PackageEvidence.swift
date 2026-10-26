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
        var findings: [Finding] = []
        var skipped: [Skipped] = []
    }

    static func scan(application: InstalledApp, roots: Roots, otherApplicationPaths: Set<String>, runner: CommandRunner) -> Result {
        let (pkgutil, lsbom) = (roots.tools.pkgutil, roots.tools.lsbom)
        let packages = packagesInstalling(application.bundlePath, runner: runner, pkgutil: pkgutil)
        guard !packages.isEmpty else { return Result() }
        var result = Result()

        // Folders every other package lists, to find the ones this app's packages share.
        let receiptNames = ((try? FileManager.default.contentsOfDirectory(atPath: roots.receipts.path)) ?? []).filter { $0.hasSuffix(".plist") }
        let ownNames = Set(packages.map { "\($0).plist".lowercased() })
        let others = receiptNames.filter { !ownNames.contains($0.lowercased()) && !$0.lowercased().hasPrefix("com.apple.") }
        let otherListings = UnsafeResults<[String]>(count: others.count)
        DispatchQueue.concurrentPerform(iterations: others.count) { index in
            otherListings[index] = listing(receipt: roots.receipts.appending(path: others[index]), directoriesOnly: true, runner: runner, lsbom: lsbom)
        }
        let sharedFolders = Set(otherListings.values.flatMap { $0 }.map { $0.lowercased() })

        for package in packages {
            // Entries inside the app's bundle are covered by deleting the bundle (Xcode's
            // receipt lists 166,000 of them).
            let paths = listing(receipt: roots.receipts.appending(path: "\(package).plist"), directoriesOnly: false, runner: runner, lsbom: lsbom, excludingInside: application.bundlePath)
            let items = ownedItems(paths, sharedFolders: sharedFolders, root: roots.systemRoot).filter { FileManager.default.fileExists(atPath: $0) || isSymbolicLink($0) }
            // A package that also installed another app still on the Mac (a suite like DaVinci
            // Resolve's) owns its files together with that app: none of them, and not its
            // receipt, belong to this app alone.
            let otherApp = items.lazy.compactMap { item -> String? in
                let lowered = item.lowercased()
                return otherApplicationPaths.first { let other = $0.lowercased(); return other == lowered || other.hasPrefix(lowered + "/") || lowered.hasPrefix(other + "/") }
            }.first
            if let otherApp {
                let name = URL(filePath: otherApp).lastPathComponent
                result.skipped.append(Skipped(path: roots.receipts.appending(path: "\(package).plist").path, reason: "package \(package) also installed \(name), so its files stay while that app is installed"))
                continue
            }
            for item in items where !Protection.isProtected(item, roots: roots) {
                result.findings.append(Finding(path: item, tier: .exact, reason: "installed by package \(package)"))
            }
            result.packages.append(package)
        }
        return result
    }

    /// Topmost entries below a standard folder, descending into any folder another package shares.
    static func ownedItems(_ paths: [String], sharedFolders: Set<String>, root: String = "/") -> [String] {
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
            if sharedFolders.contains(path.lowercased()) {
                queue += (children[path.lowercased()] ?? []).sorted()
            } else {
                owned.append(path)
            }
        }
        return owned.sorted()
    }

    /// `pkgutil --file-info` names every package that installed the bundle, Apple's App Store
    /// receipts (Xcode) included.
    static func packagesInstalling(_ path: String, runner: CommandRunner, pkgutil: URL) -> [String] {
        guard let result = try? runner.run(executable: pkgutil, arguments: ["--file-info", path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin", "LC_ALL": "C"], timeout: 10, outputLimit: 1_048_576),
              result.status == 0 else { return [] }
        var packages: [String] = []
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") where line.hasPrefix("pkgid: ") {
            let identifier = line.dropFirst("pkgid: ".count).trimmingCharacters(in: .whitespaces)
            if EmbeddedBundles.isReverseDNS(identifier), !packages.contains(identifier) { packages.append(identifier) }
        }
        return packages
    }

    /// Absolute paths listed in a receipt's BOM, resolved against its install prefix.
    static func listing(receipt plist: URL, directoriesOnly: Bool, runner: CommandRunner, lsbom: URL, excludingInside excluded: String? = nil) -> [String] {
        let bom = plist.deletingPathExtension().appendingPathExtension("bom")
        guard FileManager.default.fileExists(atPath: bom.path) else { return [] }
        var prefix = "/"
        if let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let value = info["InstallPrefixPath"] as? String { prefix = value }
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = trimmedPrefix.isEmpty ? "" : "/" + trimmedPrefix
        guard let result = try? runner.run(executable: lsbom, arguments: ["-s"] + (directoriesOnly ? ["-d"] : []) + [bom.path], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 30, outputLimit: 256 * 1_024 * 1_024),
              result.status == 0 else { return [] }
        // Lines inside `excluded` are dropped by comparing bytes, before any string is built:
        // BOM lines are relative ("./Applications/Xcode.app/…"), so compare against that form.
        var excludedLine: [UInt8]?
        if let excluded {
            let relative = base.isEmpty ? excluded : (excluded.hasPrefix(base + "/") ? String(excluded.dropFirst(base.count)) : nil)
            excludedLine = relative.map { Array(("." + $0 + "/").utf8) }
        }
        var paths: [String] = []
        result.stdout.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for index in 0...bytes.count where index == bytes.count || bytes[index] == 0x0A {
                defer { start = index + 1 }
                guard index > start else { continue }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<index])
                if let excludedLine, line.count >= excludedLine.count, line.starts(with: excludedLine) { continue }
                var relative = Substring(String(decoding: line, as: UTF8.self))
                if relative == "." { relative = "" } else if relative.hasPrefix("./") { relative = relative.dropFirst(2) }
                while relative.hasSuffix("/") { relative = relative.dropLast() }
                guard !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { continue }
                paths.append(relative.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + relative)
            }
        }
        return paths
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Folders packages install into but never own. Lowercased.
    static let standardFolders: Set<String> = Set([
        "/", "/Applications", "/Applications/Utilities", "/Users", "/Users/Shared", "/opt", "/private", "/private/etc", "/private/var", "/private/tmp", "/etc", "/var", "/tmp",
        "/usr", "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/include", "/usr/local/share", "/usr/local/etc", "/usr/local/libexec",
        "/usr/local/share/man", "/usr/local/share/man/man1", "/usr/local/share/man/man5", "/usr/local/share/man/man8", "/usr/local/share/doc",
        "/Library", "/Library/Application Support", "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/CLAP", "/Library/Audio/Plug-Ins/ARA", "/Library/Audio/MIDI Drivers",
        "/Library/Audio/MIDI Devices", "/Library/Audio/Sounds", "/Library/Audio/Apple Loops", "/Library/Application Support/Avid", "/Library/Application Support/Avid/Audio",
        "/Library/Application Support/Avid/Audio/Plug-Ins", "/Library/Application Support/Digidesign", "/Library/Application Support/Digidesign/Plug-Ins",
        "/Library/Automator", "/Library/Bundles", "/Library/Caches", "/Library/ColorPickers", "/Library/ColorSync", "/Library/ColorSync/Profiles", "/Library/Components",
        "/Library/Contextual Menu Items", "/Library/CoreMediaIO", "/Library/CoreMediaIO/Plug-Ins", "/Library/CoreMediaIO/Plug-Ins/DAL", "/Library/Desktop Pictures",
        "/Library/Dictionaries", "/Library/DirectoryServices", "/Library/DirectoryServices/PlugIns", "/Library/Documentation", "/Library/DriverExtensions", "/Library/Extensions",
        "/Library/Filesystems", "/Library/Fonts", "/Library/Frameworks", "/Library/Graphics", "/Library/Image Capture", "/Library/Image Capture/Devices",
        "/Library/Input Methods", "/Library/Internet Plug-Ins", "/Library/Java", "/Library/Java/Extensions", "/Library/Java/JavaVirtualMachines", "/Library/Keyboard Layouts",
        "/Library/Keychains", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Logs", "/Library/Mail", "/Library/Mail/Bundles", "/Library/PDF Services",
        "/Library/Perl", "/Library/PreferencePanes", "/Library/Preferences", "/Library/Printers", "/Library/PrivilegedHelperTools", "/Library/Python", "/Library/QuickLook",
        "/Library/Receipts", "/Library/Ruby", "/Library/Screen Savers", "/Library/Scripts", "/Library/Security", "/Library/Services", "/Library/Spotlight",
        "/Library/StartupItems", "/Library/SystemExtensions", "/Library/User Pictures", "/Library/Video", "/Library/Video/Plug-Ins", "/Library/WebServer", "/Library/Widgets",
        "/Library/Workflows", "/Library/Workflows/Applications", "/Library/Developer",
    ].map { $0.lowercased() })
}
