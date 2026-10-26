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

    static func findings(for application: InstalledApp, inventory: Inventory) -> [Finding] {
        guard let game = game(for: application, inventory: inventory) else { return [] }
        var findings = [
            Finding(path: game.folder, tier: .exact, reason: "Steam game folder"),
            Finding(path: game.manifest, tier: .exact, reason: "Steam manifest for app \(game.appID)"),
        ]
        for shortcut in inventory.applications where shortcut.isSteamShortcut && shortcutAppID(shortcut) == game.appID {
            findings.append(Finding(path: shortcut.path, tier: .exact, reason: "Steam shortcut"))
        }
        return findings
    }

    static func game(for application: InstalledApp, inventory: Inventory) -> Game? {
        if application.isSteamShortcut {
            guard let appID = shortcutAppID(application) else { return nil }
            // The game's own bundle tells which library it's in.
            for candidate in inventory.applications where candidate.path.contains("/steamapps/common/") {
                if let game = gameContaining(candidate.path), game.appID == appID { return game }
            }
            return nil
        }
        return gameContaining(application.path)
    }

    /// The game whose folder holds `path`, from the library's manifests.
    static func gameContaining(_ path: String) -> Game? {
        guard let range = path.range(of: "/steamapps/common/") else { return nil }
        let steamapps = String(path[..<range.lowerBound]) + "/steamapps"
        guard let installDirectory = path[range.upperBound...].split(separator: "/").first.map(String.init),
              !installDirectory.isEmpty, installDirectory != ".", installDirectory != ".." else { return nil }
        let folder = steamapps + "/common/" + installDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: steamapps)) ?? [] where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let manifest = steamapps + "/" + name
            guard let text = try? String(contentsOfFile: manifest, encoding: .utf8), text.utf8.count <= 1_048_576,
                  let directory = value("installdir", in: text), directory.caseInsensitiveCompare(installDirectory) == .orderedSame,
                  let appID = value("appid", in: text), appID.allSatisfy(\.isNumber) else { continue }
            return Game(appID: appID, folder: folder, manifest: manifest)
        }
        return nil
    }

    /// The app ID a shortcut launches, from its tiny `open steam://run/<id>` script.
    static func shortcutAppID(_ application: InstalledApp) -> String? {
        guard let executable = application.executableName else { return nil }
        let script = URL(filePath: application.bundlePath).appending(path: "Contents/MacOS").appending(path: executable)
        guard let values = try? script.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? .max) <= 4_096,
              let text = try? String(contentsOf: script, encoding: .utf8), let range = text.range(of: "steam://run/") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// A top-level `"key"  "value"` pair from a Valve KeyValues file.
    private static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if parts.count == 2, parts[0].caseInsensitiveCompare(key) == .orderedSame { return parts[1] }
        }
        return nil
    }
}
