import Foundation

/// Apps installed together with an app, which go with it. Nothing here names a product: the
/// groups come from how apps were installed, and each group's main app from general signals.
///
/// Groups an app can belong to:
/// - **Homebrew cask**: every app one cask installed. `brew uninstall` removes them all at once,
///   so they always go together, in both directions.
/// - **Installer package**: every app one receipt installed (the app's helpers in
///   `/Library/Application Support` included).
/// - **Folder**: every app in the app's folder, when that isn't an Applications folder itself
///   (`/Applications/DaVinci Resolve/`, `/Applications/Adobe Acrobat DC/`).
///
/// In a package or folder group only apps signed by the app's developer count, and only the
/// group's main app takes the others: the one named like the folder (or package), otherwise the
/// one at least twice the size of any other. A group without a clear main app (a suite of equal
/// peers) takes nothing. Two more ties only ever point one way: an app whose package installed
/// another app's installer (`<name> Installer.pkg`) takes that app, and an uninstaller named
/// after an app (`Uninstall <name>`, `<name> Uninstaller`) goes with it.
///
/// Other apps by the same developer are only mentioned.
public enum Companions {
    public struct Companion: Sendable {
        public var application: InstalledApp
        public var reason: String
        /// Removed by the same `brew uninstall` as the app: it can't be kept.
        public var inseparable = false
    }

    public struct Result: Sendable {
        public var companions: [Companion] = []
        /// Other apps signed by the same developer, not tied to the app.
        public var sameDeveloper: [InstalledApp] = []
        /// The app's own folder, when companions are in it: removed once it's empty.
        public var folder: String?
        /// Main apps of groups this app is only a member of: deleting them would take it.
        public var partOf: [InstalledApp] = []
    }

    /// `team` reads a bundle's developer team (tests stand in for real signatures).
    public static func find(for application: InstalledApp, inventory: Inventory, roots: Roots, runner: CommandRunner = CommandRunner(),
                            team teamOf: @Sendable (String) -> String? = { SigningInfo.read(URL(filePath: $0, directoryHint: .isDirectory))?.teamIdentifier }) -> Result {
        guard application.classification == .user, application.bundleIdentifier?.lowercased().hasPrefix("com.apple.") != true else { return Result() }
        var result = Result()
        var reasons: [(InstalledApp, String)] = []
        var inseparable = Set<String>()
        let byPath = Dictionary(inventory.applications.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func isOther(_ other: InstalledApp) -> Bool {
            other.path != application.path && other.bundlePath != application.bundlePath && other.classification != .system && other.bundleIdentifier?.lowercased().hasPrefix("com.apple.") != true
        }

        // Homebrew cask: brew removes all of its apps together.
        if case let .homebrew(token, true) = application.source, let cask = inventory.casks.first(where: { $0.token == token }) {
            var paths = Set(cask.appPaths.map { $0.lowercased() })
            for other in inventory.applications where cask.suitePaths.contains(where: { other.path.lowercased().hasPrefix($0.lowercased() + "/") }) { paths.insert(other.path.lowercased()) }
            for (path, packages) in inventory.receipts.packagesByApplication where packages.contains(where: { identifier in cask.packagePatterns.contains { Caskroom.package(identifier, matches: $0) } }) {
                paths.insert(path)
            }
            for other in paths.compactMap({ byPath[$0] }) where isOther(other) {
                reasons.append((other, "Homebrew's cask \(token) installed it too, and brew uninstall removes them together"))
                inseparable.insert(other.path)
            }
        }

        // Candidates for the other groups, before any signature is read (loading the Security
        // framework alone takes ~25 ms): the app's vendor, its folder, its packages, uninstallers.
        let vendor = application.bundleIdentifier.flatMap(EvidenceFinder.vendor)
        let ownName = normalized(application.name)
        let folder = URL(filePath: application.path).deletingLastPathComponent().standardizedFileURL.path
        let isApplicationsFolder = roots.applicationRoots.contains { $0.url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() == folder.lowercased() }
        let inFolder = { (other: InstalledApp) in !isApplicationsFolder && other.classification == .user && other.path.lowercased().hasPrefix(folder.lowercased() + "/") }
        let ownPackages = inventory.receipts.packages(for: application.path)
        var installedBy: [String: Set<String>] = [:]
        for (path, packages) in inventory.receipts.packagesByApplication {
            for package in packages where ownPackages.contains(package) { installedBy[package, default: []].insert(path) }
        }
        let packagePeers = installedBy.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let candidates = inventory.applications.filter { other in
            isOther(other) && ((vendor != nil && other.bundleIdentifier.flatMap(EvidenceFinder.vendor) == vendor) || inFolder(other)
                || packagePeers.contains(other.path.lowercased())
                || (other.classification == .user && uninstalls(other, application: ownName)))
        }
        var sameTeam: [InstalledApp] = []
        if !candidates.isEmpty, let team = teamOf(application.bundlePath) {
            let teams = UnsafeResults<String?>(count: candidates.count)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in teams[index] = teamOf(candidates[index].bundlePath) }
            sameTeam = zip(candidates, teams.values).filter { $0.1 == team }.map(\.0)
        }

        // Package and folder groups: the main app takes the rest.
        var groups: [(members: [InstalledApp], label: String, isFolder: Bool, reason: String)] = ownPackages.map { package in
            let paths = installedBy[package] ?? []
            return ([application] + sameTeam.filter { paths.contains($0.path.lowercased()) }, package, false, "installed by the same package (\(package))")
        }
        let folderMembers = sameTeam.filter(inFolder)
        if !folderMembers.isEmpty {
            groups.append(([application] + folderMembers, URL(filePath: folder).lastPathComponent, true, "in \(application.name)'s folder"))
        }
        for group in groups where group.members.count > 1 {
            guard let main = mainApp(of: group.members, label: group.label, isFolder: group.isFolder) else { continue }
            if main.path == application.path {
                for other in group.members where other.path != application.path { reasons.append((other, group.reason)) }
                if group.isFolder { result.folder = folder }
            } else if !result.partOf.contains(where: { $0.path == main.path }) {
                result.partOf.append(main)
            }
        }

        // An installer the app's packages put on disk, named after another app.
        let installers = ownPackages.flatMap { installerNames(inventory.receipts.listings[$0] ?? []) }
        for other in sameTeam where other.classification == .user {
            let name = normalized(other.name)
            if name.count >= 4, installers.contains(where: { $0.hasPrefix(name) }) { reasons.append((other, "its installer ships with \(application.name)")) }
            // An uninstaller named after the app.
            if uninstalls(other, application: ownName) {
                reasons.append((other, "the uninstaller named after \(application.name)"))
            }
        }

        var seen = Set<String>()
        for (other, reason) in reasons where seen.insert(other.path).inserted && !result.partOf.contains(where: { $0.path == other.path }) {
            result.companions.append(Companion(application: other, reason: reason, inseparable: inseparable.contains(other.path)))
        }
        result.companions.sort { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
        let mainPaths = Set(result.partOf.map(\.path))
        result.sameDeveloper = sameTeam.filter { $0.classification == .user && !seen.contains($0.path) && !mainPaths.contains($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    /// A group's main app: the one named like the folder or package (exactly, then as the start
    /// of a folder's name, or contained in a package identifier), otherwise, among those
    /// (or all members, for a package), the one at least twice the size of any other. A folder
    /// must be named after its main app. Uninstallers are never the main app.
    static func mainApp(of members: [InstalledApp], label: String, isFolder: Bool) -> InstalledApp? {
        var name = label
        if name.lowercased().hasSuffix(".localized") { name = String(name.dropLast(".localized".count)) }
        let key = normalized(name)
        let eligible = members.filter { uninstalledName($0.name) == nil }
        if let exact = eligible.filter({ normalized($0.name) == key }).only { return exact }
        let named = eligible.filter { member in
            let own = normalized(member.name)
            guard own.count >= 4, key.count >= 4 else { return false }
            // "Adobe Acrobat DC" is Adobe Acrobat's folder; "Wacom Tablet Utility" is a utility
            // in the "Wacom Tablet" folder, not its main app.
            return isFolder ? key.hasPrefix(own) : key.contains(own)
        }
        if let only = named.only { return only }
        if isFolder && named.isEmpty { return nil }
        let pool = (named.isEmpty ? eligible : named).sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        guard let first = pool.first, let size = first.size, size > 0 else { return nil }
        guard pool.count > 1 else { return first }
        guard let second = pool[1].size, size >= 2 * second else { return nil }
        return first
    }

    /// Whether `other` is an uninstaller named after the app (its normalized name).
    static func uninstalls(_ other: InstalledApp, application name: String) -> Bool {
        guard other.name.range(of: "uninstall", options: .caseInsensitive) != nil, let target = uninstalledName(other.name) else { return false }
        return target == name || name.hasPrefix(target) || name.hasSuffix(target)
    }

    /// For an uninstaller's name ("Uninstall Foo", "Foo Uninstaller", "Uninstaller for Foo"), the normalized name of
    /// what it uninstalls; nil for any other name or one too short to identify an app.
    static func uninstalledName(_ name: String) -> String? {
        var key = normalized(name)
        for word in ["uninstaller", "uninstall"] {
            if key.hasPrefix(word) {
                key = String(key.dropFirst(word.count))
                if key.hasPrefix("for") { key = String(key.dropFirst(3)) } // "Uninstaller for Vuze"
                return key.count >= 4 ? key : nil
            }
            if key.hasSuffix(word) { key = String(key.dropLast(word.count)); return key.count >= 4 ? key : nil }
        }
        return nil
    }

    /// Normalized names of the `.pkg` installers a listing holds ("FL Cloud Plugins
    /// Installer.pkg" → "flcloudpluginsinstaller").
    static func installerNames(_ paths: [String]) -> [String] {
        paths.compactMap { path in
            let name = URL(filePath: path).lastPathComponent
            return name.lowercased().hasSuffix(".pkg") ? normalized(String(name.dropLast(4))) : nil
        }
    }

    /// Lowercased letters and digits only.
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

private extension Array {
    /// The only element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
