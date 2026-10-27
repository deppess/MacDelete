import Foundation

/// What a plan should tell the user without deleting anything: data that may be their own, data
/// that syncs elsewhere, and system state deleting the app leaves.
enum PlanNotes {
    /// Items this large in an app's data folders often hold the user's own files (UTM's virtual
    /// machines, a music library, a project database), not just caches.
    static let largeSize: Int64 = 1_000_000_000

    static func largeData(_ findings: [Finding], roots: Roots) -> [String] {
        let library = roots.home.appending(path: "Library").path + "/"
        let folders = ["Containers/", "Group Containers/", "Application Support/"]
        return findings.filter { finding in
            // Data folders only: not the app itself, a Steam game, or Steam's own client.
            finding.size >= largeSize && !["Steam's client and data", "Steam game folder"].contains(finding.reason ?? "")
                && !finding.path.lowercased().contains("/application support/steam/") && folders.contains { finding.path.hasPrefix(library + $0) }
        }.map { "\(Format.path($0.path, home: roots.home).terminalInline) is \(Format.size($0.size)): it may hold files of your own (documents, libraries, virtual machines). Check before deleting." }
    }

    /// The app's iCloud folder (`~/Library/Mobile Documents/iCloud~com~vendor~app`), which syncs
    /// to the user's other devices, and its cloud-storage folders (`~/Library/CloudStorage/Dropbox`,
    /// `GoogleDrive-<account>`), which hold the user's files. Never deleted: listed as kept. Read
    /// directly, so a folder macOS won't list (without Full Disk Access) adds no warning.
    static func cloudData(identifiers: [String], names: [String], roots: Roots) -> [Skipped] {
        var kept: [Skipped] = []
        let mobile = roots.home.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let icloudNames = Set(identifiers.map { "icloud~" + $0.lowercased().replacingOccurrences(of: ".", with: "~") })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: mobile.path)) ?? [] where icloudNames.contains(name.lowercased()) {
            kept.append(Skipped(path: mobile.appending(path: name).path, reason: "its iCloud data, which syncs to your other devices: remove it in System Settings › Apple Account › iCloud if you want it gone"))
        }
        let storage = roots.home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let squeezed = Set(names.flatMap { name -> [String] in
            let words = name.split(separator: " ").map(String.init)
            return [words.joined(), words.dropFirst().joined()].filter { $0.count >= 3 }.map { $0.lowercased() }
        })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? [] {
            let provider = name.split(separator: "-").first.map { String($0).lowercased() } ?? ""
            if squeezed.contains(provider) {
                kept.append(Skipped(path: storage.appending(path: name).path, reason: "your cloud files: sign out in the app first, then remove the folder yourself"))
            }
        }
        return kept
    }

    /// Whether the app has a tile in the user's Dock, which turns into a question mark once it's gone.
    static func isInDock(_ appPath: String, roots: Roots) -> Bool {
        let plist = roots.home.appending(path: "Library/Preferences/com.apple.dock.plist")
        guard let dock = SmallFile.plist(atPath: plist.path, limit: 8 * 1_048_576),
              let tiles = dock["persistent-apps"] as? [[String: Any]] else { return false }
        let target = URL(filePath: appPath, directoryHint: .isDirectory).standardizedFileURL.path
        return tiles.contains { tile in
            guard let file = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String, let url = URL(string: string) ?? Optional(URL(filePath: string)) else { return false }
            return url.standardizedFileURL.path == target
        }
    }

    /// Kernel extensions of the app's (by identifier). They stay: unloading one needs the vendor's
    /// uninstaller or Recovery, and a half-removed kext can stop the Mac from starting cleanly.
    static func kernelExtensions(ownership: Ownership, roots: Roots) -> [Skipped] {
        let folder = roots.library.appending(path: "Extensions", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name in
            guard name.lowercased().hasSuffix(".kext") else { return nil }
            let item = folder.appending(path: name)
            guard let identifier = PluginBundles.bundleIdentifier(of: item), ownership.owner(ofItemNamed: identifier) == .target else { return nil }
            return Skipped(path: item.path, reason: "its kernel extension: remove it with the vendor's uninstaller, then restart")
        }
    }
}
