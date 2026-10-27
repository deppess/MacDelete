import Foundation

/// Every installed application with its source and size.
public struct Inventory: Sendable {
    public var applications: [InstalledApp]
    public var casks: [InstalledCask]
    public var receipts: PackageReceipts
    public var warnings: [String]
    public var complete: Bool

    /// Scans the roots, the Caskroom and the package receipts concurrently, then works out each
    /// app's source. `sizes` fills in any size Spotlight didn't have by walking those bundles.
    public static func load(roots: Roots, runner: CommandRunner = CommandRunner(), sizes: Bool = true, timing: Timing? = nil) -> Inventory {
        let casksTask = Concurrent { Caskroom.installedCasks(prefixes: roots.homebrewPrefixes, home: roots.home) }
        let receiptsTask = Concurrent { PackageReceipts.read(directory: roots.receipts, runner: runner) }
        // Game folders that are their own bundle (Stardew Valley) never have a Spotlight size and
        // take the longest to walk (11,000 files), so they're walked while the scan runs.
        let folderBundleSizes: Concurrent<[String: Int64]>? = sizes ? Concurrent { folderBundleSizes(roots: roots) } : nil
        let scan = AppScanner(roots: roots, runner: runner).scan()
        timing?.mark("scan")
        let casks = casksTask.value
        let receipts = receiptsTask.value
        timing?.mark("caskroom + receipts")

        var applications = scan.applications.map { application in
            var application = application
            application.source = source(of: application, casks: casks, receipts: receipts)
            return application
        }
        if sizes {
            let early = folderBundleSizes?.value ?? [:]
            for index in applications.indices where applications[index].size == nil {
                if let size = early[URL(filePath: applications[index].bundlePath).standardizedFileURL.path.lowercased()] { applications[index].size = size }
            }
            let missing = applications.indices.filter { applications[$0].size == nil && applications[$0].classification == .user }
            let bundlePaths = missing.map { applications[$0].bundlePath }
            let measured = UnsafeResults<Int64>(count: missing.count)
            DispatchQueue.concurrentPerform(iterations: bundlePaths.count) { index in
                measured[index] = DiskUsage.allocatedSize(of: bundlePaths[index]).bytes
            }
            for (index, size) in zip(missing, measured.values) { applications[index].size = size }
            timing?.mark("sizes (\(missing.count) walked)")
        }
        return Inventory(applications: applications, casks: casks, receipts: receipts, warnings: scan.warnings, complete: scan.complete)
    }

    /// Sizes of the bundles directly in roots that allow extensionless bundles, by lowercased path.
    static func folderBundleSizes(roots: Roots) -> [String: Int64] {
        let folders = roots.applicationRoots.filter(\.extensionlessBundles).flatMap { root -> [String] in
            let base = root.url.standardizedFileURL.path
            guard case let .success(names) = Directory.names(atPath: base) else { return [] }
            return names.filter { !$0.hasPrefix(".") && !$0.lowercased().hasSuffix(".app") }.map { base + "/" + $0 }
                .filter { FileManager.default.fileExists(atPath: $0 + "/Contents/Info.plist") }
        }
        let results = UnsafeResults<Int64>(count: folders.count)
        DispatchQueue.concurrentPerform(iterations: folders.count) { index in results[index] = DiskUsage.allocatedSize(of: folders[index]).bytes }
        return Dictionary(zip(folders.map { $0.lowercased() }, results.values), uniquingKeysWith: { first, _ in first })
    }

    /// A Steam desktop shortcut is shown as part of its game: dropped when the game it launches
    /// (matched by Steam app ID) is in the list. A shortcut whose game is gone stays.
    public static func foldingSteamShortcuts(_ applications: [InstalledApp]) -> [InstalledApp] {
        guard applications.contains(where: \.isSteamShortcut) else { return applications }
        let installedGames = Set(applications.filter { !$0.isSteamShortcut && $0.source == .steam }.compactMap { SteamGame.gameContaining($0.path)?.appID })
        return applications.filter { application in
            guard application.isSteamShortcut, let appID = SteamGame.shortcutAppID(application) else { return true }
            return !installedGames.contains(appID)
        }
    }

    /// Homebrew first (it manages the app even when the cask runs an installer package), then the
    /// App Store, Steam, Setapp, an installer package, and otherwise a plain download.
    static func source(of application: InstalledApp, casks: [InstalledCask], receipts: PackageReceipts) -> AppSource {
        if application.classification == .system { return .macOS }
        let path = application.path.lowercased()
        let packages = receipts.packages(for: application.path)
        for cask in casks {
            if cask.appPaths.contains(where: { $0.lowercased() == path })
                || cask.suitePaths.contains(where: { path.hasPrefix($0.lowercased() + "/") })
                || packages.contains(where: { identifier in cask.packagePatterns.contains { Caskroom.package(identifier, matches: $0) } }) {
                return .homebrew(token: cask.token, declared: true)
            }
        }
        for cask in casks where application.linkTargets.contains(where: { $0.hasPrefix(cask.caskroomPath) }) {
            return .homebrew(token: cask.token, declared: false)
        }
        if application.hasAppStoreReceipt { return .appStore }
        if application.isSteamShortcut || application.path.range(of: "/steamapps/common/", options: .caseInsensitive) != nil { return .steam }
        if application.path.hasPrefix("/Applications/Setapp/") { return .setapp }
        if application.path.hasPrefix("/Applications/MacPorts/") { return .macPorts }
        if !packages.isEmpty { return .installerPackage(identifiers: packages) }
        return .download
    }
}

/// Phase timings, printed to standard error when DELETE_TIMING=1.
public final class Timing: @unchecked Sendable {
    private let start = DispatchTime.now()
    private var last = DispatchTime.now()
    private var lines: [String] = []
    private let lock = NSLock()

    public init() {}

    public func mark(_ phase: String) {
        lock.withLock {
            let now = DispatchTime.now()
            lines.append(Self.line(phase, Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000))
            last = now
        }
    }

    public var report: String {
        lock.withLock {
            let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            return (lines + [Self.line("total", total)]).joined(separator: "\n")
        }
    }

    private static func line(_ phase: String, _ milliseconds: Double) -> String {
        phase.padding(toLength: max(phase.count, 28), withPad: " ", startingAt: 0) + String(format: "%8.1f ms", milliseconds)
    }
}
