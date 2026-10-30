import Foundation

/// A Steam game is a folder in a library's `steamapps/common`, described by an
/// `appmanifest_<id>.acf` beside it; the `.app` inside is a small part of it. Steam's desktop
/// shortcuts (`steam://run/<id>` bundles) belong to the game too. Steam's own folder is never
/// touched beyond these exact items.
enum SteamGame {
    struct Game: Equatable {
        var appID: String
        var folder: String
        var manifest: String
    }

    static func findings(for application: InstalledApp, inventory: Inventory, home: URL) -> [Finding] {
        guard let game = game(for: application, inventory: inventory, home: home) else { return [] }
        var findings = [
            Finding(path: game.folder, tier: .exact, reason: "Steam game folder"),
            Finding(path: game.manifest, tier: .exact, reason: "Steam manifest for app \(game.appID)")
        ]
        for shortcut in inventory.applications where shortcut.isSteamShortcut && shortcutAppID(shortcut) == game.appID {
            findings.append(Finding(path: shortcut.path, tier: .exact, reason: "Steam shortcut"))
        }
        return findings
    }

    static func game(for application: InstalledApp, inventory: Inventory, home: URL) -> Game? {
        if application.isSteamShortcut {
            guard let appID = shortcutAppID(application) else { return nil }
            // The game's own bundle tells which library it's in.
            var libraries = [home.appending(path: "Library/Application Support/Steam/steamapps").path]
            for candidate in inventory.applications where candidate.path.range(of: "/steamapps/common/", options: .caseInsensitive) != nil {
                if let game = gameContaining(candidate.path), game.appID == appID { return game }
                if let range = candidate.path.range(of: "/steamapps/common/", options: .caseInsensitive) {
                    libraries.append(String(candidate.path[..<range.lowerBound]) + "/steamapps")
                }
            }
            // A game without a bundle the scan found: its manifest names its folder.
            for steamapps in Set(libraries) {
                let manifest = steamapps + "/appmanifest_\(appID).acf"
                guard let text = manifestText(manifest), value("appid", in: text) == appID, let directory = value("installdir", in: text),
                    !directory.isEmpty, !directory.contains("/"), directory != ".", directory != ".."
                else { continue }
                let folder = steamapps + "/common/" + directory
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                return Game(appID: appID, folder: folder, manifest: manifest)
            }
            return nil
        }
        return gameContaining(application.path)
    }

    static func manifestText(_ path: String) -> String? { SmallFile.text(atPath: path) }

    /// The game whose folder holds `path`, from the library's manifests.
    static func gameContaining(_ path: String) -> Game? {
        guard let range = path.range(of: "/steamapps/common/", options: .caseInsensitive) else { return nil }
        let steamapps = String(path[..<range.lowerBound]) + "/steamapps"
        guard let installDirectory = path[range.upperBound...].split(separator: "/").first.map(String.init),
            !installDirectory.isEmpty, installDirectory != ".", installDirectory != ".."
        else { return nil }
        let folder = steamapps + "/common/" + installDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: steamapps)) ?? [] where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let manifest = steamapps + "/" + name
            guard let text = manifestText(manifest),
                let directory = value("installdir", in: text), directory.caseInsensitiveCompare(installDirectory) == .orderedSame,
                let appID = value("appid", in: text), appID.allSatisfy(\.isNumber)
            else { continue }
            return Game(appID: appID, folder: folder, manifest: manifest)
        }
        return nil
    }

    /// The app ID a shortcut launches, from its tiny `open steam://run/<id>` script.
    static func shortcutAppID(_ application: InstalledApp) -> String? {
        guard let executable = application.executableName else { return nil }
        let script = URL(filePath: application.bundlePath).appending(path: "Contents/MacOS").appending(path: executable)
        guard let text = SmallFile.text(atPath: script.path, limit: 4_096), let range = text.range(of: "steam://run/") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// A top-level `"key"  "value"` pair from a Valve KeyValues file.
    static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if parts.count == 2, parts[0].caseInsensitiveCompare(key) == .orderedSame { return parts[1] }
        }
        return nil
    }

    /// Steam itself: its own folder holds the real client (`Steam.AppBundle`), caches, logs,
    /// settings and local user data, all Steam's (the user decided deleting Steam takes all of
    /// it, 2026-10-26). Installed games stay: each is an installed app of its own, and one app's
    /// deletion never takes another's. Steam's leftovers inside `steamapps` (downloads, shader
    /// caches, workshop items, manifests of games no longer there) go; the folders left empty go.
    struct SteamClient {
        var findings: [Finding] = []
        var skipped: [Skipped] = []
        var emptyFolders: [String] = []
        var launchItems: [LaunchItem] = []
    }

    static func client(roots: Roots, others: [InstalledApp], collector: inout Collector) -> SteamClient {
        var result = SteamClient()
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        let steam = library.appending(path: "Application Support/Steam", directoryHint: .isDirectory)
        let steamappsName = collector.list(steam).first { $0.lowercased() == "steamapps" } ?? "steamapps"
        let steamapps = steam.appending(path: steamappsName, directoryHint: .isDirectory)
        let commonName = collector.list(steamapps).first { $0.lowercased() == "common" } ?? "common"
        let common = steamapps.appending(path: commonName, directoryHint: .isDirectory)

        // Games Steam lists as installed (by manifest), with the names the scan gave them.
        var installed: [String: (name: String, manifest: String)] = [:]
        for name in collector.list(steamapps) where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let manifest = steamapps.appending(path: name).path
            guard let text = manifestText(manifest), let directory = value("installdir", in: text), !directory.isEmpty, !directory.contains("/"),
                FileManager.default.fileExists(atPath: common.appending(path: directory).path)
            else { continue }
            let title =
                others.first { $0.path.hasPrefix(common.appending(path: directory).path + "/") || $0.path == common.appending(path: directory).path }?.name
                ?? value("name", in: text) ?? directory
            installed[directory.lowercased()] = (title, manifest)
        }
        let keptManifests = Set(installed.values.map(\.manifest))

        // Older installs name it "SteamApps"; the file system ignores case, so must this.
        for name in collector.list(steam) where name.lowercased() != "steamapps" && !name.hasPrefix(".") {
            result.findings.append(Finding(path: steam.appending(path: name).path, tier: .exact, reason: "Steam's client and data"))
        }
        for name in collector.list(steamapps) where !name.hasPrefix(".") {
            let path = steamapps.appending(path: name).path
            if name.lowercased() == "common" {
                for game in collector.list(common) where !game.hasPrefix(".") {
                    let folder = common.appending(path: game).path
                    if let entry = installed[game.lowercased()] {
                        result.skipped.append(
                            Skipped(path: folder, reason: "\(entry.name) is installed: delete it first (delete \(Format.shellQuoted(entry.name)))"))
                    } else {
                        result.findings.append(Finding(path: folder, tier: .exact, reason: "files of a game Steam no longer lists"))
                    }
                }
            } else if keptManifests.contains(path) {
                continue
            } else {
                result.findings.append(
                    Finding(
                        path: path, tier: .exact,
                        reason: name.hasPrefix("appmanifest_") ? "manifest of a game no longer installed" : "Steam's downloads and caches"))
            }
        }
        result.emptyFolders = [common.path, steamapps.path, steam.path].filter { FileManager.default.fileExists(atPath: $0) }

        let cache = library.appending(path: "Caches/Steam")
        if FileManager.default.fileExists(atPath: cache.path) { result.findings.append(Finding(path: cache.path, tier: .exact, reason: "Steam's cache")) }
        // Steam's cleanup agent, whose label isn't a sub-identifier of Steam's.
        let agent = library.appending(path: "LaunchAgents/com.valvesoftware.steamclean.plist")
        if let job = LaunchItemScan.read(agent), job.label == "com.valvesoftware.steamclean" {
            result.findings.append(Finding(path: agent.path, tier: .exact, reason: "launch agent"))
            result.launchItems.append(LaunchItem(label: job.label, plist: agent.path, domain: .user))
        }
        return result
    }
}
