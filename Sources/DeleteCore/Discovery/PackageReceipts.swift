import Foundation

/// Which installer packages placed which application bundles, from the receipts in
/// /var/db/receipts. Each receipt's BOM is listed once (`lsbom -s -d`, directories only), in
/// parallel: about 0.15 s for every package on a typical Mac, against one `pkgutil --file-info`
/// process per app.
public struct PackageReceipts: Sendable {
    /// Package identifiers by lowercased bundle path (APFS is case-insensitive by default).
    public var packagesByApplication: [String: [String]]

    public init(packagesByApplication: [String: [String]] = [:]) {
        self.packagesByApplication = packagesByApplication
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
        let results = UnsafeResults<[String]>(count: receipts.count)
        DispatchQueue.concurrentPerform(iterations: receipts.count) { index in
            let receipt = receipts[index]
            guard let result = try? runner.run(executable: lsbom, arguments: ["-s", "-d", receipt.bom.path], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 20, outputLimit: 64 * 1_024 * 1_024),
                  result.status == 0 else { results[index] = []; return }
            results[index] = applicationPaths(bomOutput: result.stdout, installPrefix: receipt.prefix)
        }
        var map: [String: [String]] = [:]
        for (receipt, paths) in zip(receipts, results.values) {
            for path in paths where !(map[path.lowercased()]?.contains(receipt.identifier) ?? false) {
                map[path.lowercased(), default: []].append(receipt.identifier)
            }
        }
        return PackageReceipts(packagesByApplication: map)
    }

    /// Top-level `.app` directories in a BOM listing. Listed paths are relative to the receipt's
    /// install prefix, which is usually "/" but may itself be the bundle
    /// (`Applications/FL Cloud Plugins.app`, listed as ".").
    static func applicationPaths(bomOutput: Data, installPrefix: String) -> [String] {
        let base = URL(filePath: "/" + installPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")), directoryHint: .isDirectory)
        return String(decoding: bomOutput, as: UTF8.self).split(separator: "\n").compactMap { line in
            var relative = String(line)
            if relative == "." { relative = "" } else if relative.hasPrefix("./") { relative = String(relative.dropFirst(2)) }
            let url = (relative.isEmpty ? base : base.appending(path: relative)).standardizedFileURL
            guard url.pathExtension.lowercased() == "app", !url.deletingLastPathComponent().pathComponents.contains(where: { ["app", "framework", "bundle", "xpc", "appex", "plugin", "kext"].contains(URL(filePath: $0).pathExtension.lowercased()) }) else { return nil }
            return url.path
        }
    }
}
