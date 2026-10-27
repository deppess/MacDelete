import Foundation

/// Apps installed together with an app, which go with it (FL Studio's FL Cloud Plugins, the
/// utilities in DaVinci Resolve's folder). A companion is signed by the same developer and tied
/// to the app in one direction, so deleting a companion never takes the app:
///
/// - the app's folder holds it (`/Applications/DaVinci Resolve/` holds DaVinci Resolve and its
///   utilities);
/// - a package that installed the app installed it too, and the app is the largest that package
///   installed (DaVinci Resolve's package also installs Blackmagic Proxy Generator Lite);
/// - one of the app's packages installed its installer (`FL Cloud Plugins Installer.pkg` inside
///   FL Studio).
///
/// Other apps by the same developer (Micro Snitch beside Little Snitch) are only mentioned.
public enum Companions {
    public struct Companion: Sendable {
        public var application: InstalledApp
        public var reason: String
    }

    public struct Result: Sendable {
        public var companions: [Companion] = []
        /// Other apps signed by the same developer, not tied to the app.
        public var sameDeveloper: [InstalledApp] = []
        /// The app's own folder, when companions are in it: removed once it's empty.
        public var folder: String?
    }

    /// `team` reads a bundle's developer team (tests stand in for real signatures).
    public static func find(for application: InstalledApp, inventory: Inventory, roots: Roots, runner: CommandRunner = CommandRunner(),
                            team teamOf: @Sendable (String) -> String? = { SigningInfo.read(URL(filePath: $0, directoryHint: .isDirectory))?.teamIdentifier }) -> Result {
        guard application.classification == .user, let identifier = application.bundleIdentifier, let vendor = EvidenceFinder.vendor(identifier), vendor != "com.apple" else { return Result() }
        // Only apps of the same vendor, in the app's folder or from its packages have their signatures read. Helper
        // apps outside the Applications folders (auxiliary) count only when the app's package
        // installed them too.
        let folder = URL(filePath: application.path).deletingLastPathComponent().standardizedFileURL.path
        // The app's own folder: named after it, and not an applications folder itself.
        let isRoot = roots.applicationRoots.contains { $0.url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() == folder.lowercased() }
        let ownFolder = !isRoot && URL(filePath: folder).lastPathComponent.caseInsensitiveCompare(application.name) == .orderedSame
        let ownPackages = inventory.receipts.packages(for: application.path)
        // Bundles (lowercased paths) by each of the app's packages, from the receipt map's few
        // dozen entries rather than a lookup per installed app.
        var installedBy: [String: Set<String>] = [:]
        for (path, packages) in inventory.receipts.packagesByApplication {
            for package in packages where ownPackages.contains(package) { installedBy[package, default: []].insert(path) }
        }
        let packagePeers = installedBy.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let candidates = inventory.applications.filter { other in
            guard other.path != application.path, other.bundlePath != application.bundlePath, other.classification != .system,
                  other.bundleIdentifier?.lowercased().hasPrefix("com.apple.") != true else { return false }
            return other.bundleIdentifier.flatMap(EvidenceFinder.vendor) == vendor || (ownFolder && other.path.lowercased().hasPrefix(folder.lowercased() + "/"))
                || packagePeers.contains(other.path.lowercased())
        }
        // Signatures are read only now: loading the Security framework alone takes ~25 ms.
        guard !candidates.isEmpty, let team = teamOf(application.bundlePath) else { return Result() }
        let teams = UnsafeResults<String?>(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            teams[index] = teamOf(candidates[index].bundlePath)
        }
        let sameTeam = zip(candidates, teams.values).filter { $0.1 == team }.map(\.0)
        guard !sameTeam.isEmpty else { return Result() }

        var reasons: [String: String] = [:]
        if ownFolder {
            for other in sameTeam where other.classification == .user && other.path.lowercased().hasPrefix(folder.lowercased() + "/") {
                reasons[other.path] = reasons[other.path] ?? "in \(application.name)'s folder"
            }
        }
        // Installed by the same package, the app being the largest that package installed.
        for package in ownPackages {
            let paths = installedBy[package] ?? []
            let installed = inventory.applications.filter { paths.contains($0.path.lowercased()) }
            guard let size = application.size, installed.allSatisfy({ $0.path == application.path || ($0.size ?? .max) < size }) else { continue }
            for other in sameTeam where installed.contains(where: { $0.path == other.path }) {
                reasons[other.path] = reasons[other.path] ?? "installed by the same package (\(package))"
            }
        }
        // An installer one of the app's packages put on disk, named after the other app.
        let installers = ownPackages.flatMap { installerNames(receipt: roots.receipts.appending(path: "\($0).plist"), runner: runner, lsbom: roots.tools.lsbom) }
        for other in sameTeam where other.classification == .user {
            let name = normalized(other.name)
            guard name.count >= 4, installers.contains(where: { $0.hasPrefix(name) }) else { continue }
            reasons[other.path] = reasons[other.path] ?? "its installer ships with \(application.name)"
        }

        var result = Result()
        if reasons.values.contains(where: { $0.hasPrefix("in ") }) { result.folder = folder }
        for other in sameTeam.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if let reason = reasons[other.path] {
                result.companions.append(Companion(application: other, reason: reason))
            } else if other.classification == .user {
                result.sameDeveloper.append(other)
            }
        }
        return result
    }

    /// Normalized names of the `.pkg` installers a receipt lists ("FL Cloud Plugins
    /// Installer.pkg" → "flcloudpluginsinstaller"). The listing is scanned as bytes: a receipt can
    /// list tens of thousands of files.
    static func installerNames(receipt plist: URL, runner: CommandRunner, lsbom: URL) -> [String] {
        let bom = plist.deletingPathExtension().appendingPathExtension("bom")
        guard FileManager.default.fileExists(atPath: bom.path),
              let result = try? runner.run(executable: lsbom, arguments: ["-s", bom.path], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 30, outputLimit: 256 * 1_024 * 1_024),
              result.status == 0 else { return [] }
        var names: [String] = []
        for line in result.stdout.split(separator: 0x0A) where line.count > 4 {
            let suffix = line.suffix(4).map { $0 | 0x20 }
            guard suffix == Array(".pkg".utf8) else { continue }
            let file = String(decoding: line, as: UTF8.self).split(separator: "/").last.map(String.init) ?? ""
            names.append(normalized(String(file.dropLast(4))))
        }
        return names
    }

    /// Lowercased letters and digits only.
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
