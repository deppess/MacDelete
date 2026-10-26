import Foundation

/// Finds everything an app left on the system, looking only in fixed locations, never by
/// crawling the disk.
public struct EvidenceFinder: Sendable {
    public let roots: Roots
    private let runner: CommandRunner

    public init(roots: Roots, runner: CommandRunner = CommandRunner()) {
        self.roots = roots
        self.runner = runner
    }

    public func plan(for application: InstalledApp, inventory: Inventory, timing: Timing? = nil) throws(Refusal) -> RemovalPlan {
        if let refusal = Protection.refusal(for: application) { throw refusal }
        let bundle = URL(filePath: application.bundlePath, directoryHint: .isDirectory)

        // Identifiers: the app's, its embedded helpers', and its privileged helper tools' labels.
        let embedded = EmbeddedBundles.find(in: bundle, mainIdentifier: application.bundleIdentifier)
        let helperLabels = EmbeddedBundles.privilegedHelperLabels(in: bundle)
        // A template's placeholder identifier (Unity's com.Company.ProductName) is shared by
        // unrelated apps, so it's no evidence; only the app's name finds its files then.
        let placeholder = application.bundleIdentifier.flatMap { Self.isPlaceholder($0) ? $0 : nil }
        var identifiers: [String] = placeholder == nil ? application.bundleIdentifier.map { [$0] } ?? [] : []
        for identifier in embedded.map(\.identifier) + helperLabels where !Self.isPlaceholder(identifier) && !identifiers.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) {
            identifiers.append(identifier)
        }
        // A helper app installed outside the bundle (iStat Menus keeps its agents' apps in
        // Application Support) shows up as a separate bundle, but a sub-identifier of the app's
        // makes it the app's own.
        let lowerOwn = identifiers.map { $0.lowercased() }
        let others = inventory.applications.filter { other in
            guard other.bundlePath != application.bundlePath, other.path != application.path else { return false }
            guard other.classification == .auxiliary, let identifier = other.bundleIdentifier?.lowercased() else { return true }
            return !lowerOwn.contains { identifier.hasPrefix($0 + ".") }
        }
        let ownership = Ownership(targetPath: application.bundlePath, targetIdentifiers: identifiers, otherApplications: others)
        timing?.mark("  embedded bundles (\(embedded.count))")
        // How to describe an item that belongs to a helper rather than the app itself.
        var helperKinds: [String: String] = [:]
        for item in embedded { helperKinds[item.identifier.lowercased()] = Self.kind(of: item.path) }
        for label in helperLabels { helperKinds[label.lowercased()] = "privileged helper" }

        // Slower lookups run while the folders are listed.
        let runner = self.runner
        let roots = self.roots
        let otherPaths = Set(others.flatMap { [$0.path, $0.bundlePath] })
        let packagesTask = Concurrent { PackageEvidence.scan(application: application, roots: roots, otherApplicationPaths: otherPaths, runner: runner) }
        let groupsTask = Concurrent { Self.applicationGroups(bundle: bundle, embedded: embedded, others: others) }
        let catalogTask: Concurrent<(token: String, paths: [String])?>? = {
            if case .homebrew(_, true) = application.source { return nil }
            return Concurrent { HomebrewZap.catalogPaths(for: application, catalog: roots.homebrewCatalog) }
        }()

        var collector = Collector(roots: roots)
        collector.add(Finding(path: application.path, tier: .exact), exempt: true)
        if application.path != application.bundlePath { collector.add(Finding(path: application.bundlePath, tier: .exact, reason: "the app the link points to"), exempt: true) }

        // Items named by an identifier.
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        var identifierFolders: [(URL, String?)] = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Saved Application State", "HTTPStorages", "WebKit",
            "Cookies", "Logs", "Application Scripts", "Autosave Information", "SyncedPreferences", "Input Methods", "Group Containers",
        ].map { (library.appending(path: $0, directoryHint: .isDirectory), nil) }
        identifierFolders += [
            (library.appending(path: "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"), "recent documents list"),
            (library.appending(path: "Caches/com.plausiblelabs.crashreporter.data"), "crash data"),
        ]
        identifierFolders += ["Application Support", "Caches", "Preferences", "Logs", "Input Methods"].map { (roots.library.appending(path: $0, directoryHint: .isDirectory), nil) }
        identifierFolders += [
            (roots.library.appending(path: "PrivilegedHelperTools"), nil),
            (roots.library.appending(path: "Receipts"), "old installer receipt"),
        ]
        identifierFolders += [roots.userCache, roots.userTemp].compactMap { $0 }.map { ($0, "temporary files") }
        if let clones = roots.codeSigningClones { identifierFolders.append((clones, "code-signing copy")) }

        for (folder, reason) in identifierFolders {
            for name in collector.list(folder) {
                switch ownership.owner(ofItemNamed: name) {
                case .target?:
                    let via = Self.matchedIdentifier(name, identifiers: identifiers)
                    let helperNote = via.flatMap { helperKinds[$0.lowercased()] }
                    collector.add(Finding(path: folder.appending(path: name).path, tier: .exact, reason: [reason, helperNote].compactMap { $0 }.joined(separator: ", ").nonEmpty))
                case let .shared(other)?:
                    collector.skip(folder.appending(path: name).path, "also belongs to \(Format.path(other, home: roots.home))")
                case .other?, nil:
                    continue
                }
            }
        }

        timing?.mark("  identifier folders")
        // Sandbox containers named by UUID (iOS and Catalyst apps), identified by their metadata.
        let containers = library.appending(path: "Containers", directoryHint: .isDirectory)
        let lowerIdentifiers = Set(identifiers.map { $0.lowercased() })
        for name in collector.list(containers) where UUID(uuidString: name) != nil {
            let metadata = containers.appending(path: "\(name)/.com.apple.containermanagerd.metadata.plist")
            guard let data = try? Data(contentsOf: metadata), data.count <= 1_048_576,
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let owner = info["MCMMetadataIdentifier"] as? String, lowerIdentifiers.contains(owner.lowercased()) else { continue }
            collector.add(Finding(path: containers.appending(path: name).path, tier: .exact, reason: "container of \(owner)"))
        }

        // App groups named in the entitlements, unless another installed app uses the same group.
        let groups = groupsTask.value
        timing?.mark("  app groups")
        for group in groups.own {
            for folder in ["Group Containers", "Application Scripts"].map({ library.appending(path: $0, directoryHint: .isDirectory) }) {
                guard let name = collector.list(folder).first(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) else { continue }
                let path = folder.appending(path: name).path
                if let other = groups.claimedBy[group.lowercased()] {
                    collector.skip(path, "app group shared with \(other)")
                } else {
                    collector.add(Finding(path: path, tier: .exact, reason: "app group"))
                }
            }
        }

        // Launch agents and daemons, and the helpers they run.
        let launch = LaunchItemScan.scan(roots: roots, bundlePath: application.bundlePath, identifiers: identifiers, helperLabels: helperLabels, ownership: ownership)
        launch.findings.forEach { collector.add($0) }
        collector.unreadable += launch.unreadable

        // Browser native-messaging manifests that run a program inside the app.
        for finding in NativeMessaging.findings(bundlePath: application.bundlePath, roots: roots, collector: &collector) { collector.add(finding) }

        // Installer packages.
        timing?.mark("  launch items")
        let packages = packagesTask.value
        timing?.mark("  packages")
        packages.findings.forEach { collector.add($0) }
        packages.skipped.forEach { collector.skip($0.path, $0.reason) }

        // Xcode's build data, the music apps' sound libraries.
        let specific = AppSpecific.findings(for: application, others: others, roots: roots)
        specific.findings.forEach { collector.add($0) }
        specific.skipped.forEach { collector.skip($0.path, $0.reason) }

        // Steam games: the game's folder and its manifest, and any desktop shortcut.
        for finding in SteamGame.findings(for: application, inventory: inventory, home: roots.home) { collector.add(finding, exempt: true) }

        // Homebrew's zap list: exact for a cask Homebrew installed (brew would delete it too),
        // name evidence from the catalog otherwise.
        var homebrewCask: String?
        var emptyFolders: [String] = []
        if case let .homebrew(token, true) = application.source, let cask = inventory.casks.first(where: { $0.token == token }) {
            homebrewCask = token
            let zap = HomebrewZap.installedCaskPaths(token: token, prefix: cask.prefix)
            for pattern in zap.remove {
                for path in HomebrewZap.expand(pattern, home: roots.home) {
                    // An item another installed app's identifier names stays, whatever the list says.
                    switch ownership.owner(ofItemNamed: URL(filePath: path).lastPathComponent) {
                    case let .other(owner)?, let .shared(owner)?: collector.skip(path, "also belongs to \(Format.path(owner, home: roots.home))")
                    default: collector.add(Finding(path: path, tier: .exact, reason: "Homebrew zap"))
                    }
                }
            }
            for pattern in zap.removeIfEmpty {
                for path in HomebrewZap.expand(pattern, home: roots.home) where !emptyFolders.contains(path) {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { emptyFolders.append(path) }
                }
            }
        } else if let match = catalogTask?.value ?? nil {
            for pattern in match.paths {
                for path in HomebrewZap.expand(pattern, home: roots.home) {
                    if case .other? = ownership.owner(ofItemNamed: URL(filePath: path).lastPathComponent) { continue }
                    if case .shared? = ownership.owner(ofItemNamed: URL(filePath: path).lastPathComponent) { continue }
                    collector.add(Finding(path: path, tier: .name, reason: "Homebrew's list for \(match.token)"))
                }
            }
        }

        // Items named only by the app's name.
        for finding in nameFindings(application, others: others, collector: &collector) { collector.add(finding) }

        timing?.mark("  steam, homebrew, names")
        var findings = collector.finish(otherApplicationPaths: otherPaths)
        // A folder the zap list removes only when empty is never deleted whole, not even as a name match.
        let lowerEmpty = Set(emptyFolders.map { $0.lowercased() })
        findings.removeAll { lowerEmpty.contains($0.path.lowercased()) }
        Self.measure(&findings, knownBundle: application.size.map { (application.bundlePath, $0) })
        timing?.mark("  sizes")
        let unreadable = Array(Set(collector.unreadable + findings.filter { !$0.sizeComplete }.map(\.path))).sorted()

        var notes: [String] = []
        if let placeholder { notes.append("Its bundle identifier \(placeholder.terminalInline) is a template's placeholder that other apps share, so only its name was used to find its files.") }
        let running = RunningApps.isRunning(identifiers: identifiers, bundlePath: application.bundlePath)
        let activeExtensions = activeSystemExtensions(embedded: embedded)
        notes += activeExtensions.map { "Its system extension \($0) is active. Deleting the app doesn't remove it; turn it off in the app (or System Settings › General › Login Items & Extensions) first." }
        let hasBackgroundItems = ["Contents/Library/LoginItems", "Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons"].contains { FileManager.default.fileExists(atPath: bundle.appending(path: $0).path) }
        if hasBackgroundItems { notes.append("Its entries in System Settings › General › Login Items & Extensions are removed by macOS once the app is gone.") }

        var plan = RemovalPlan(application: application, identifiers: identifiers, findings: findings, skipped: collector.skipped, launchItems: launch.items, packages: packages.packages,
                               unreadable: unreadable, notes: notes, running: running, homebrewCask: homebrewCask)
        plan.activeSystemExtensions = activeExtensions
        plan.emptyFolders = emptyFolders
        return plan
    }

    // MARK: - Name evidence

    private func nameFindings(_ application: InstalledApp, others: [InstalledApp], collector: inout Collector) -> [Finding] {
        let otherNames = Set(others.flatMap { [$0.name] + $0.alternateNames + [$0.executableName].compactMap { $0 } }.map { $0.lowercased() })
        // The app's names, plus each without a trailing version or letter ("CleanShot X" keeps
        // its data in "CleanShot", "FL Studio 2026" in "FL Studio").
        var candidates = [application.name] + application.alternateNames + [application.executableName].compactMap { $0 }
        for name in candidates {
            let words = name.split(separator: " ")
            if words.count > 1, let last = words.last, last.count == 1 || last.allSatisfy(\.isNumber) { candidates.append(words.dropLast().joined(separator: " ")) }
        }
        let names = Self.distinct(candidates)
            .filter { $0.count >= 3 && !Self.commonWords.contains($0.lowercased()) && !otherNames.contains($0.lowercased()) }
        guard !names.isEmpty else { return [] }
        let lowerNames = Set(names.map { $0.lowercased() })
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        var findings: [Finding] = []

        /// The name itself, or followed by a version ("iStat Menus 7").
        func isNamed(_ entry: String) -> Bool {
            let lowered = entry.lowercased()
            if lowerNames.contains(lowered) { return true }
            guard let space = lowered.lastIndex(of: " ") else { return false }
            let version = lowered[lowered.index(after: space)...]
            return !version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." } && lowerNames.contains(String(lowered[..<space]))
        }
        for folder in ["Application Support", "Caches", "Logs", "Caches/SentryCrash"].map({ library.appending(path: $0, directoryHint: .isDirectory) }) {
            for name in collector.list(folder) where isNamed(name) || (folder.lastPathComponent == "Logs" && name.lowercased().hasSuffix(".log") && isNamed(String(name.dropLast(4)))) {
                findings.append(Finding(path: folder.appending(path: name).path, tier: .name, reason: "named after the app"))
            }
        }
        let preferences = library.appending(path: "Preferences", directoryHint: .isDirectory)
        for name in collector.list(preferences) where name.lowercased().hasSuffix(".plist") {
            let base = String(name.dropLast(6))
            if !base.contains("."), isNamed(base) { findings.append(Finding(path: preferences.appending(path: name).path, tier: .name, reason: "named after the app")) }
        }
        let config = roots.home.appending(path: ".config", directoryHint: .isDirectory)
        let dotNames = Set(lowerNames.flatMap { [$0, $0.replacingOccurrences(of: " ", with: ""), $0.replacingOccurrences(of: " ", with: "-")] })
        for name in collector.list(config) where dotNames.contains(name.lowercased()) {
            findings.append(Finding(path: config.appending(path: name).path, tier: .name, reason: "named after the app"))
        }
        for name in collector.list(roots.home) where name.hasPrefix(".") && dotNames.contains(String(name.dropFirst()).lowercased()) {
            findings.append(Finding(path: roots.home.appending(path: name).path, tier: .name, reason: "named after the app"))
        }
        if let executable = application.executableName?.lowercased(), executable.count >= 3, !otherNames.contains(executable) {
            let reports = library.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory)
            for name in collector.list(reports) {
                let lowered = name.lowercased()
                guard lowered.hasPrefix(executable + "-") || lowered.hasPrefix(executable + "_") || lowered.hasPrefix(executable + "."),
                      [".ips", ".crash", ".diag", ".spin", ".hang"].contains(where: lowered.hasSuffix) else { continue }
                findings.append(Finding(path: reports.appending(path: name).path, tier: .name, reason: "crash report"))
            }
            let crashReporter = library.appending(path: "Application Support/CrashReporter", directoryHint: .isDirectory)
            for name in collector.list(crashReporter) where name.lowercased().hasPrefix(executable + "_") && name.lowercased().hasSuffix(".plist") {
                findings.append(Finding(path: crashReporter.appending(path: name).path, tier: .name, reason: "crash reporter state"))
            }
        }
        return findings
    }

    /// Generic words that are no evidence on their own (from Mole's list of common launch-agent words).
    static let commonWords: Set<String> = ["music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts", "messages", "reminders", "clock", "weather",
        "stocks", "books", "news", "podcasts", "voice", "files", "store", "system", "helper", "agent", "daemon", "service", "update", "updater", "sync", "backup", "cloud",
        "manager", "monitor", "server", "client", "worker", "runner", "launcher", "driver", "plugin", "extension", "widget", "utility", "app", "application", "electron",
        "chrome", "chromium", "java", "python", "node", "setup", "installer", "uninstaller", "main", "default", "data", "cache", "caches", "logs", "temp", "tmp"]

    // MARK: - Helpers

    /// Identifiers project templates fill in until the developer sets one (Unity, Xcode's old
    /// templates), found in shipped games.
    static func isPlaceholder(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if ["com.company.productname", "unity.company.productname", "com.yourcompany.productname"].contains(lowered) { return true }
        return ["com.defaultcompany.", "unity.defaultcompany.", "com.yourcompany.", "com.mycompany."].contains { lowered.hasPrefix($0) }
    }

    static func kind(of embeddedPath: String) -> String {
        switch URL(filePath: embeddedPath).pathExtension.lowercased() {
        case "appex": "app extension"
        case "xpc": "XPC service"
        case "systemextension": "system extension"
        default: embeddedPath.contains("/Contents/Library/LoginItems/") ? "login item" : "helper app"
        }
    }

    /// The longest of the app's identifiers that names `item`.
    static func matchedIdentifier(_ item: String, identifiers: [String]) -> String? {
        let lowered = item.lowercased()
        return identifiers.filter { lowered == $0.lowercased() || lowered.hasPrefix($0.lowercased() + ".") }.max { $0.count < $1.count }
    }

    /// The app's own app groups (from it and its embedded bundles), and which of them another
    /// installed app also lists. Only apps outside /System are read: a third-party group can't
    /// appear in Apple's system apps, and reading those signatures is slow (~0.6 s for all).
    static func applicationGroups(bundle: URL, embedded: [EmbeddedBundles.Embedded], others: [InstalledApp]) -> (own: [String], claimedBy: [String: String]) {
        var own: [String] = []
        for url in [bundle] + embedded.map({ URL(filePath: $0.path, directoryHint: .isDirectory) }) {
            for group in SigningInfo.read(url)?.applicationGroups ?? [] where !own.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) { own.append(group) }
        }
        guard !own.isEmpty else { return ([], [:]) }
        let candidates = others.filter { $0.classification != .system }
        let results = UnsafeResults<[String]>(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            results[index] = SigningInfo.read(URL(filePath: candidates[index].bundlePath, directoryHint: .isDirectory))?.applicationGroups ?? []
        }
        let lowerOwn = Set(own.map { $0.lowercased() })
        var claimedBy: [String: String] = [:]
        for (other, groups) in zip(candidates, results.values) {
            for group in groups where lowerOwn.contains(group.lowercased()) { claimedBy[group.lowercased()] = other.name }
        }
        return (own, claimedBy)
    }

    private func activeSystemExtensions(embedded: [EmbeddedBundles.Embedded]) -> [String] {
        let extensions = embedded.filter { $0.path.lowercased().hasSuffix(".systemextension") }
        guard !extensions.isEmpty,
              let result = try? runner.run(executable: roots.tools.systemextensionsctl, arguments: ["list"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 10, outputLimit: 1_048_576),
              result.status == 0 else { return [] }
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        return extensions.filter { item in lines.contains { $0.contains("\t\(item.identifier) (") && $0.contains("activated") } }.map(\.identifier)
    }

    /// Sizes and permissions, measured in parallel. The app bundle's size comes from Spotlight
    /// when it has one (a bundle can hold tens of thousands of files); its ownership is then
    /// judged by its top folders, where installers set it.
    private static func measure(_ findings: inout [Finding], knownBundle: (path: String, size: Int64)?) {
        let paths = findings.map(\.path)
        let results = UnsafeResults<(Int64, Bool, Bool)>(count: paths.count)
        let uid = getuid()
        let isRoot = geteuid() == 0
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let path = paths[index]
            let parentWritable = access(URL(filePath: path).deletingLastPathComponent().path, W_OK) == 0
            if let knownBundle, knownBundle.path == path {
                let foreign = [path, path + "/Contents", path + "/Contents/MacOS"].contains { item in
                    var info = stat()
                    return lstat(item, &info) == 0 && info.st_uid != uid
                }
                results[index] = (knownBundle.size, true, !isRoot && (foreign || !parentWritable))
                return
            }
            let usage = DiskUsage.allocatedSize(of: path, owner: isRoot ? nil : uid)
            results[index] = (usage.bytes, usage.complete, !isRoot && (usage.foreignOwned || !parentWritable))
        }
        for (index, result) in results.values.enumerated() {
            (findings[index].size, findings[index].sizeComplete, findings[index].needsRoot) = result
        }
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Gathers findings: lists each folder once, keeps the strongest finding per path, and applies
/// the rules every finding must pass.
struct Collector {
    let roots: Roots
    private var listings: [String: [String]] = [:]
    private var findings: [Finding] = []
    private var exempt = Set<String>()
    private(set) var skipped: [Skipped] = []
    var unreadable: [String] = []

    init(roots: Roots) { self.roots = roots }

    /// The names in a folder, read once. A folder that exists but can't be read is recorded:
    /// without Full Disk Access, macOS hides other apps' data, and "nothing found" would be wrong.
    mutating func list(_ folder: URL) -> [String] {
        if let cached = listings[folder.path] { return cached }
        var names: [String] = []
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            let code = (error as NSError).underlyingErrors.first.map { ($0 as NSError).code } ?? (error as NSError).code
            if FileManager.default.fileExists(atPath: folder.path) || code == Int(EPERM) || code == Int(EACCES) || code == NSFileReadNoPermissionError { unreadable.append(folder.path) }
        }
        listings[folder.path] = names
        return names
    }

    /// `exempt` findings (the app itself, a Steam game's folder) were chosen by the user or
    /// verified separately, so the protected-folder rules don't apply to them.
    mutating func add(_ finding: Finding, exempt isExempt: Bool = false) {
        let path = URL(filePath: finding.path).standardizedFileURL.path
        var finding = finding
        finding.path = path
        if isExempt { exempt.insert(path.lowercased()) }
        if let index = findings.firstIndex(where: { $0.path.lowercased() == path.lowercased() }) {
            if findings[index].tier == .name, finding.tier == .exact { findings[index] = finding }
            return
        }
        findings.append(finding)
    }

    mutating func skip(_ path: String, _ reason: String) {
        guard !skipped.contains(where: { $0.path == path }) else { return }
        skipped.append(Skipped(path: path, reason: reason))
    }

    /// Drops anything protected, inside or containing another installed app, reached through a
    /// symbolic link, or already inside another finding.
    mutating func finish(otherApplicationPaths: Set<String>) -> [Finding] {
        let lowerOthers = otherApplicationPaths.map { $0.lowercased() }
        var kept: [Finding] = []
        for finding in findings {
            let lowered = finding.path.lowercased()
            let isExempt = exempt.contains(lowered)
            if !isExempt, Protection.isProtected(finding.path, roots: roots) {
                if finding.tier == .exact { skip(finding.path, "protected location") }
                continue
            }
            if !isExempt, lowerOthers.contains(where: { $0 == lowered || $0.hasPrefix(lowered + "/") || lowered.hasPrefix($0 + "/") }) {
                skip(finding.path, "belongs to another installed app")
                continue
            }
            // The folder holding the item must be where its path says, not somewhere a link leads.
            let parent = URL(filePath: finding.path).deletingLastPathComponent()
            if parent.resolvingSymlinksInPath().path != parent.path, !Self.isSystemLink(parent.path) {
                skip(finding.path, "reached through a symbolic link")
                continue
            }
            kept.append(finding)
        }
        // An item inside another selected item is covered by it.
        let sorted = kept.sorted { $0.path.count < $1.path.count }
        var result: [Finding] = []
        for finding in sorted {
            let lowered = finding.path.lowercased()
            if let parent = result.first(where: { lowered.hasPrefix($0.path.lowercased() + "/") }), parent.tier == .exact || finding.tier == .name { continue }
            result.append(finding)
        }
        return result.sorted { ($0.tier == .exact ? 0 : 1, $0.path) < ($1.tier == .exact ? 0 : 1, $1.path) }
    }

    /// macOS's own links (/var → /private/var, /tmp → /private/tmp) don't count.
    private static func isSystemLink(_ path: String) -> Bool {
        ["/var", "/tmp", "/etc"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
