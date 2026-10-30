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

    /// `group` are the paths of apps deleted together with this one (its companions, or the app
    /// they go with): they don't count as other installed apps, so nothing is kept for them.
    public func plan(for application: InstalledApp, inventory: Inventory, group: Set<String> = [], timing: Timing? = nil) throws(Refusal) -> RemovalPlan {
        if let refusal = Protection.refusal(for: application) { throw refusal }
        if case let .homebrew(token, true) = application.source,
            let cask = inventory.casks.first(where: { $0.token == token }), !cask.mayReplicateUninstall
        {
            throw Refusal(
                message:
                    "\(application.name) was installed by Homebrew cask \(token), which has uninstall actions delete cannot yet model exactly (\(cask.unsupportedUninstallArtifacts.joined(separator: ", "))). Nothing was deleted; use Homebrew or the vendor's uninstaller until those actions are supported."
            )
        }
        let bundle = URL(filePath: application.bundlePath, directoryHint: .isDirectory)

        // Identifiers: the app's, its embedded helpers', and its privileged helper tools' labels.
        let embedded = EmbeddedBundles.find(in: bundle, mainIdentifier: application.bundleIdentifier)
        let helperLabels = EmbeddedBundles.privilegedHelperLabels(in: bundle)
        // A template's placeholder identifier (Unity's com.Company.ProductName) is shared by
        // unrelated apps, so it's no evidence; only the app's name finds its files then.
        let placeholder = application.bundleIdentifier.flatMap { Self.isPlaceholder($0) ? $0 : nil }
        var identifiers: [String] = placeholder == nil ? application.bundleIdentifier.map { [$0] } ?? [] : []
        for identifier in embedded.map(\.identifier) + helperLabels
        where !Self.isPlaceholder(identifier) && !identifiers.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) {
            identifiers.append(identifier)
        }
        if case let .homebrew(token, true) = application.source,
            let cask = inventory.casks.first(where: { $0.token == token }), !cask.quitIdentifiers.isEmpty
        {
            let known = Set(identifiers.map { $0.lowercased() })
            let unknown = cask.quitIdentifiers.filter { !known.contains($0.lowercased()) }
            guard unknown.isEmpty else {
                throw Refusal(
                    message:
                        "\(application.name) was installed by Homebrew cask \(token), whose declared quit identifier\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", ")) does not belong to the app or an embedded component. Nothing was deleted; delete will not terminate an unrelated process."
                )
            }
        }
        // A helper app installed outside the bundle (iStat Menus keeps its agents' apps in
        // Application Support) shows up as a separate bundle, but a sub-identifier of the app's
        // makes it the app's own.
        let lowerOwn = identifiers.map { $0.lowercased() }
        let others = inventory.applications.filter { other in
            guard other.bundlePath != application.bundlePath, other.path != application.path, !group.contains(other.path) else { return false }
            guard other.classification == .auxiliary, let identifier = other.bundleIdentifier?.lowercased() else { return true }
            return !lowerOwn.contains { identifier.hasPrefix($0 + ".") }
        }
        // A helper whose identifier isn't the app's own family (Office's shared error reporter) may
        // be embedded in other apps of the same vendor too; those apps are read to find out.
        let ownership = Ownership(
            targetPath: application.bundlePath, targetIdentifiers: identifiers, otherApplications: others,
            otherEmbedded: Self.sharedEmbedded(identifiers: identifiers, main: application.bundleIdentifier, others: others))
        timing?.mark("  embedded bundles (\(embedded.count))")
        // How to describe an item that belongs to a helper rather than the app itself.
        var helperKinds: [String: String] = [:]
        for item in embedded { helperKinds[item.identifier.lowercased()] = Self.kind(of: item.path) }
        for label in helperLabels { helperKinds[label.lowercased()] = "privileged helper" }

        // Slower lookups run while the folders are listed.
        let runner = self.runner
        let roots = self.roots
        let otherPaths = Set(others.flatMap { [$0.path, $0.bundlePath] })
        let packagesTask = Concurrent {
            PackageEvidence.scan(application: application, receipts: inventory.receipts, roots: roots, otherApplicationPaths: otherPaths, runner: runner)
        }
        let groupsTask = Concurrent { Self.applicationGroups(bundle: bundle, embedded: embedded, others: others) }
        let catalogTask: Concurrent<(token: String, paths: [String])?>? = {
            if case .homebrew(_, true) = application.source { return nil }
            return Concurrent { HomebrewZap.catalogPaths(for: application, catalog: roots.homebrewCatalog) }
        }()

        var collector = Collector(roots: roots)
        collector.add(Finding(path: application.path, tier: .exact), exempt: true)
        if application.path != application.bundlePath {
            collector.add(Finding(path: application.bundlePath, tier: .exact, reason: "the app the link points to"), exempt: true)
        }

        // Items named by an identifier.
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        var identifierFolders: [(URL, String?)] = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Saved Application State", "HTTPStorages", "WebKit",
            "Cookies", "Logs", "Application Scripts", "Autosave Information", "SyncedPreferences", "Input Methods", "Group Containers"
        ].map { (library.appending(path: $0, directoryHint: .isDirectory), nil) }
        identifierFolders += [
            (
                library.appending(path: "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"),
                "recent documents list"
            ),
            (library.appending(path: "Caches/com.plausiblelabs.crashreporter.data"), "crash data"),
            // Help Viewer's copy of the app's help book (`<id>.help*<version>`).
            (library.appending(path: "Caches/com.apple.helpd/Generated"), "help cache"),
            (library.appending(path: "Caches/com.apple.nsurlsessiond/Downloads"), "background downloads"),
            (library.appending(path: "WebKit/Databases/___IndexedDB"), "web storage"),
            (library.appending(path: "Preferences/com.apple.FileProvider"), "file provider settings")
        ]
        identifierFolders += ["Application Support", "Caches", "Preferences", "Logs", "Input Methods"].map {
            (roots.library.appending(path: $0, directoryHint: .isDirectory), nil)
        }
        identifierFolders += [
            (roots.library.appending(path: "PrivilegedHelperTools"), nil),
            (roots.library.appending(path: "Receipts"), "old installer receipt")
        ]
        identifierFolders += [roots.userCache, roots.userTemp].compactMap { $0 }.map { ($0, "temporary files") }
        if let clones = roots.codeSigningClones { identifierFolders.append((clones, "code-signing copy")) }

        for (folder, reason) in identifierFolders {
            // Most entries can't be the app's at all; they're ruled out before the ownership rules.
            for name in collector.list(folder) where ownership.mightBelongToTarget(name) {
                switch ownership.owner(ofItemNamed: name) {
                case .target?:
                    let via = Self.matchedIdentifier(name, identifiers: identifiers)
                    let helperNote = via.flatMap { helperKinds[$0.lowercased()] }
                    collector.add(
                        Finding(
                            path: folder.appending(path: name).path, tier: .exact,
                            reason: [reason, helperNote].compactMap { $0 }.joined(separator: ", ").nonEmpty))
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
            guard let info = SmallFile.plist(atPath: metadata.path),
                let owner = info["MCMMetadataIdentifier"] as? String, lowerIdentifiers.contains(owner.lowercased())
            else { continue }
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
        let cask = {
            if case let .homebrew(token, true) = application.source { return inventory.casks.first { $0.token == token } }
            return nil
        }()
        // A cask's launchctl label is only a locator, never ownership evidence. The resolved
        // plist must independently belong to the app through its association, program, or the
        // complete ownership index.
        let launch = LaunchItemScan.scan(
            roots: roots, bundlePath: application.bundlePath, identifiers: identifiers,
            helperLabels: helperLabels, ownership: ownership)
        if let cask, !cask.launchctlLabels.isEmpty {
            let found = Set(launch.items.map { $0.label.lowercased() })
            let missing = cask.launchctlLabels.filter { !found.contains($0.lowercased()) }
            if !missing.isEmpty {
                throw Refusal(
                    message:
                        "\(application.name) was installed by Homebrew cask \(cask.token), whose declared launch item\(missing.count == 1 ? "" : "s") \(missing.joined(separator: ", ")) could not be resolved to an installed LaunchAgent or LaunchDaemon plist. Nothing was deleted; delete will not guess how to stop a launchd service."
                )
            }
        }
        launch.findings.forEach { collector.add($0) }
        collector.unreadable += launch.unreadable

        // Command-line links into the app, and plug-ins it installed into the Library.
        for finding in CommandLinks.findings(bundlePath: application.bundlePath, roots: roots, collector: &collector) { collector.add(finding) }
        let plugins = PluginBundles.scan(application: application, ownership: ownership, roots: roots, collector: &collector)
        plugins.findings.forEach { collector.add($0) }
        plugins.skipped.forEach { collector.skip($0.path, $0.reason) }

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
        var emptyFolders: [String] = []
        var extraLaunchItems: [LaunchItem] = []
        if application.bundleIdentifier?.lowercased() == "com.valvesoftware.steam" {
            let client = SteamGame.client(roots: roots, others: others, collector: &collector)
            // Exempt from the protected-folder rule (they're inside Steam's folder), never from
            // the rule that another installed app's files stay.
            client.findings.forEach { collector.add($0, exempt: true, keepOtherAppsCheck: true) }
            client.skipped.forEach { collector.skip($0.path, $0.reason) }
            emptyFolders += client.emptyFolders
            extraLaunchItems += client.launchItems
        }

        // Homebrew's zap list: exact for a cask Homebrew installed (brew would delete it too),
        // name evidence from the catalog otherwise.
        let zap = HomebrewZap.evidence(for: application, casks: inventory.casks, catalog: catalogTask?.value ?? nil, ownership: ownership, home: roots.home)
        zap.findings.forEach { collector.add($0) }
        zap.skipped.forEach { collector.skip($0.path, $0.reason) }
        emptyFolders += zap.emptyFolders

        // Items named only by the app's name.
        for finding in nameFindings(application, others: others, collector: &collector) { collector.add(finding) }

        timing?.mark("  steam, homebrew, names")
        var findings = collector.finish(otherApplicationPaths: otherPaths)
        // A folder removed only once empty is never deleted whole, not even as a name match.
        let lowerEmpty = Set(emptyFolders.map { $0.lowercased() })
        findings.removeAll { lowerEmpty.contains($0.path.lowercased()) }
        // Other receipts the plan empties.
        let coveredPackages = PackageEvidence.coveredPackages(
            findings: findings, application: application, excluding: packages.packages + packages.kept, receipts: inventory.receipts, roots: roots)
        timing?.mark("  covered packages")
        Self.measure(&findings, knownBundle: application.size.map { (application.bundlePath, $0) })
        timing?.mark("  sizes")
        let unreadable = Array(Set(collector.unreadable + findings.filter { !$0.sizeComplete }.map(\.path))).sorted()

        let running = RunningApps.isRunning(identifiers: identifiers, bundlePath: application.bundlePath)
        let activeExtensions = activeSystemExtensions(embedded: embedded)
        var notes: [String] = []
        if let placeholder {
            notes.append(
                "Its bundle identifier \(placeholder.terminalInline) is a template's placeholder that other apps share, so only its name was used to find its files."
            )
        }
        notes += activeExtensions.map {
            "Its system extension \($0) is active. Deleting the app doesn't remove it; turn it off in the app (or System Settings › General › Login Items & Extensions) first."
        }
        notes += PlanNotes.notes(for: application, bundle: bundle, findings: findings, others: others, roots: roots)
        PlanNotes.cloudData(identifiers: identifiers, names: [application.name] + application.alternateNames, roots: roots).forEach {
            collector.skip($0.path, $0.reason)
        }
        PlanNotes.kernelExtensions(ownership: ownership, roots: roots).forEach { collector.skip($0.path, $0.reason) }

        // A folder that goes once empty isn't "kept" (Steam's, which its own rule empties).
        let skipped = collector.skipped.filter { !lowerEmpty.contains($0.path.lowercased()) }.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let caskPackages: [String]
        if let cask {
            caskPackages = inventory.receipts.listings.keys.filter { identifier in
                cask.packagePatterns.contains { Caskroom.package(identifier, matches: $0) }
            }.sorted()
        } else {
            caskPackages = []
        }
        var plan = RemovalPlan(
            application: application, identifiers: identifiers, findings: findings, skipped: skipped, launchItems: launch.items,
            packages: Array(Set(packages.packages + coveredPackages + caskPackages)).sorted(),
            unreadable: unreadable, notes: notes, running: running, homebrewCask: zap.cask)
        plan.activeSystemExtensions = activeExtensions
        plan.emptyFolders = emptyFolders
        plan.launchItems += extraLaunchItems.filter { item in !plan.launchItems.contains { $0.plist == item.plist } }
        return plan
    }

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

    /// Identifiers embedded in other apps that this app embeds too.  A helper identifier isn't
    /// necessarily in the main app's vendor namespace: LibreWolf and Tor Browser, for example,
    /// both embed `org.mozilla.updater`.  Scan every other installed third-party app rather than
    /// using the main bundle identifier as a proxy for ownership.
    static func sharedEmbedded(identifiers: [String], main: String?, others: [InstalledApp]) -> [(identifier: String, path: String)] {
        let own = main?.lowercased() ?? ""
        let foreign = identifiers.map { $0.lowercased() }.filter { $0 != own && !$0.hasPrefix(own + ".") }
        guard !foreign.isEmpty else { return [] }
        let lowerForeign = Set(foreign)
        let candidates = others.filter { $0.classification != .system }
        var result: [(identifier: String, path: String)] = []
        for other in candidates {
            for item in EmbeddedBundles.find(in: URL(filePath: other.bundlePath, directoryHint: .isDirectory), mainIdentifier: other.bundleIdentifier)
            where lowerForeign.contains(item.identifier.lowercased()) {
                result.append((item.identifier, other.path))
            }
        }
        return result
    }

    /// `com.microsoft` from `com.microsoft.errorreporting`.
    static func vendor(_ identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : nil
    }

    /// The app's own app groups (from it and its embedded bundles), and which of them another
    /// installed app also lists. Only apps outside /System are read: a third-party group can't
    /// appear in Apple's system apps, and reading those signatures is slow (~0.6 s for all).
    static func applicationGroups(bundle: URL, embedded: [EmbeddedBundles.Embedded], others: [InstalledApp]) -> (own: [String], claimedBy: [String: String]) {
        var own: [String] = []
        for url in [bundle] + embedded.map({ URL(filePath: $0.path, directoryHint: .isDirectory) }) {
            for group in SigningInfo.read(url)?.applicationGroups ?? [] where !own.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
                own.append(group)
            }
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
            let result = try? runner.run(
                executable: roots.tools.systemextensionsctl, arguments: ["list"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 10,
                outputLimit: 1_048_576),
            result.status == 0
        else { return [] }
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
            var info = stat()
            findings[index].isLink = lstat(findings[index].path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
        }
    }

    static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
