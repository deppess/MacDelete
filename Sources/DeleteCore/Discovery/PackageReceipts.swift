import Foundation

/// Every installer package's listing, read once: which packages placed which application
/// bundles, and every path each package installed. Each receipt's BOM is listed once
/// (`lsbom -s`), in parallel, while the apps are scanned (~35 ms for every package on a typical
/// Mac); plans then look things up here instead of running `lsbom` or `pkgutil` again.
public struct PackageReceipts: Sendable {
    /// Package identifiers by lowercased bundle path (APFS is case-insensitive by default).
    public var packagesByApplication: [String: [String]]
    /// Every absolute path each package lists, by package identifier.
    public var listings: [String: [String]]
    /// The same paths lowercased, for lookups (made once, while the apps are scanned).
    public var lowercasedListings: [String: Set<String>]

    public init(packagesByApplication: [String: [String]] = [:], listings: [String: [String]] = [:]) {
        self.packagesByApplication = packagesByApplication
        self.listings = listings
        lowercasedListings = listings.mapValues { Set($0.map { $0.lowercased() }) }
    }

    private init(packagesByApplication: [String: [String]], listings: [String: [String]], lowercasedListings: [String: Set<String>]) {
        (self.packagesByApplication, self.listings, self.lowercasedListings) = (packagesByApplication, listings, lowercasedListings)
    }

    /// Whether any package but these lists the (lowercased) path.
    public func isListed(_ lowercasedPath: String, byOtherThan packages: Set<String>) -> Bool {
        lowercasedListings.contains { !packages.contains($0.key.lowercased()) && $0.value.contains(lowercasedPath) }
    }

    public func packages(for path: String) -> [String] {
        packagesByApplication[URL(filePath: path).standardizedFileURL.path.lowercased()] ?? []
    }

    /// Apple's own packages are skipped: App Store installs of Apple apps leave receipts too
    /// (Xcode's BOM alone is 41 MB), and those apps are identified by their App Store receipt.
    public static func read(directory: URL, runner: CommandRunner = CommandRunner(), lsbom: URL = URL(filePath: "/usr/bin/lsbom")) -> PackageReceipts {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return PackageReceipts() }
        let receipts: [(identifier: String, prefix: String, bom: URL)] = names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            let plist = directory.appending(path: name)
            guard let info = SmallFile.plist(atPath: plist.path) else { return nil }
            let identifier = (info["PackageIdentifier"] as? String) ?? String(name.dropLast(".plist".count))
            guard !identifier.lowercased().hasPrefix("com.apple.") else { return nil }
            let bom = directory.appending(path: String(name.dropLast(".plist".count)) + ".bom")
            guard FileManager.default.fileExists(atPath: bom.path) else { return nil }
            return (identifier, (info["InstallPrefixPath"] as? String) ?? "/", bom)
        }
        let results = UnsafeResults<([String], Set<String>)>(count: receipts.count)
        DispatchQueue.concurrentPerform(iterations: receipts.count) { index in
            let receipt = receipts[index]
            let paths = listing(bom: receipt.bom, installPrefix: receipt.prefix, runner: runner, lsbom: lsbom)
            results[index] = (paths, Set(paths.map { $0.lowercased() }))
        }
        var map: [String: [String]] = [:]
        var listings: [String: [String]] = [:]
        var lowercased: [String: Set<String>] = [:]
        for (receipt, (paths, lowered)) in zip(receipts, results.values) {
            (listings[receipt.identifier], lowercased[receipt.identifier]) = (paths, lowered)
            for path in applicationPaths(paths) where !(map[path.lowercased()]?.contains(receipt.identifier) ?? false) {
                map[path.lowercased(), default: []].append(receipt.identifier)
            }
        }
        return PackageReceipts(packagesByApplication: map, listings: listings, lowercasedListings: lowercased)
    }

    /// The absolute paths a BOM lists, or none when it can't be read.
    static func listing(bom: URL, installPrefix: String, runner: CommandRunner, lsbom: URL, excludingInside excluded: String? = nil) -> [String] {
        guard let result = try? runner.run(executable: lsbom, arguments: ["-s", bom.path], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 30, outputLimit: 256 * 1_024 * 1_024),
              result.status == 0 else { return [] }
        return paths(bomOutput: result.stdout, installPrefix: installPrefix, excludingInside: excluded)
    }

    /// Absolute paths from `lsbom -s` output, resolved against the receipt's install prefix,
    /// which is usually "/" but may itself be the bundle (`Applications/FL Cloud Plugins.app`,
    /// listed as "."). Lines inside `excluded` are dropped by comparing bytes, before any string
    /// is built (Xcode's receipt lists 166,000 paths inside its bundle).
    static func paths(bomOutput: Data, installPrefix: String, excludingInside excluded: String? = nil) -> [String] {
        let trimmedPrefix = installPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = trimmedPrefix.isEmpty ? "" : "/" + trimmedPrefix
        // BOM lines are relative ("./Applications/Xcode.app/…"), so compare against that form.
        var excludedLine: [UInt8]?
        if let excluded {
            let relative = base.isEmpty ? excluded : (excluded.hasPrefix(base + "/") ? String(excluded.dropFirst(base.count)) : nil)
            excludedLine = relative.map { Array(("." + $0 + "/").utf8) }
        }
        // Byte work per line, one string per path: a receipt can list tens of thousands.
        let baseBytes = Array(base.utf8)
        var paths: [String] = []
        var buffer: [UInt8] = []
        bomOutput.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for index in 0...bytes.count where index == bytes.count || bytes[index] == 0x0A {
                defer { start = index + 1 }
                guard index > start else { continue }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<index])
                if let excludedLine, line.count >= excludedLine.count, line.starts(with: excludedLine) { continue }
                // "." is the prefix itself; "./x" is x; trailing slashes go.
                var from = line.startIndex, to = line.endIndex
                if line.count == 1, line[from] == 0x2E { from = to } else if line.count >= 2, line[from] == 0x2E, line[from + 1] == 0x2F { from += 2 }
                while to > from, line[to - 1] == 0x2F { to -= 1 }
                let relative = UnsafeBufferPointer(rebasing: line[from..<to])
                if hasDotComponent(relative) { continue }
                buffer.removeAll(keepingCapacity: true)
                buffer += baseBytes
                if relative.isEmpty {
                    if baseBytes.isEmpty { buffer.append(0x2F) }
                } else {
                    buffer.append(0x2F)
                    buffer += relative
                }
                paths.append(String(decoding: buffer, as: UTF8.self))
            }
        }
        return paths
    }

    /// Whether a relative path has a "." or ".." component, which no listing should.
    private static func hasDotComponent(_ path: UnsafeBufferPointer<UInt8>) -> Bool {
        var componentStart = path.startIndex
        for index in path.startIndex...path.endIndex where index == path.endIndex || path[index] == 0x2F {
            let length = index - componentStart
            if (length == 1 && path[componentStart] == 0x2E) || (length == 2 && path[componentStart] == 0x2E && path[componentStart + 1] == 0x2E) { return true }
            componentStart = index + 1
        }
        return false
    }

    /// Top-level `.app` bundles among a listing's paths (not helpers inside another bundle).
    static func applicationPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            // Only a path ending in ".app" is split into components.
            guard path.utf8.count > 4, path.utf8.suffix(4).map({ $0 | 0x20 }) == Array(".app".utf8) else { return false }
            let components = path.split(separator: "/")
            guard let last = components.last, last.lowercased().hasSuffix(".app") else { return false }
            return !components.dropLast().contains { component in
                let lowered = component.lowercased()
                return ["app", "framework", "bundle", "xpc", "appex", "plugin", "kext"].contains { lowered.hasSuffix("." + $0) }
            }
        }
    }

    static func applicationPaths(bomOutput: Data, installPrefix: String) -> [String] {
        applicationPaths(paths(bomOutput: bomOutput, installPrefix: installPrefix))
    }
}
