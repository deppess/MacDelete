import Foundation

/// Exact artifacts whose names are owned by the application's bundle identifier or an embedded
/// component's identifier. The locations are fixed; this never searches arbitrary directories.
enum IdentifierEvidence {
    static func collect(
        into collector: inout Collector,
        identifiers: [String],
        ownership: Ownership,
        helperKinds: [String: String],
        roots: Roots
    ) {
        for (folder, reason) in folders(roots: roots) {
            // Most entries cannot be the app's at all, so reject them before the ownership lookup.
            for name in collector.list(folder) where ownership.mightBelongToTarget(name) {
                let path = folder.appending(path: name).path
                switch ownership.owner(ofItemNamed: name) {
                case .target?:
                    let identifier = EvidenceFinder.matchedIdentifier(name, identifiers: identifiers)
                    let helperNote = identifier.flatMap { helperKinds[$0.lowercased()] }
                    collector.add(
                        Finding(
                            path: path,
                            tier: .exact,
                            reason: [reason, helperNote].compactMap { $0 }.joined(separator: ", ").nonEmpty))
                case let .shared(other)?:
                    collector.skip(path, "also belongs to \(Format.path(other, home: roots.home))")
                case .other?, nil:
                    continue
                }
            }
        }
    }

    private static func folders(roots: Roots) -> [(URL, String?)] {
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        var folders: [(URL, String?)] = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "Logs",
            "Application Scripts", "Autosave Information", "SyncedPreferences", "Input Methods",
            "Group Containers"
        ].map { (library.appending(path: $0, directoryHint: .isDirectory), nil) }
        folders += [
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
        folders += ["Application Support", "Caches", "Preferences", "Logs", "Input Methods"].map {
            (roots.library.appending(path: $0, directoryHint: .isDirectory), nil)
        }
        folders += [
            (roots.library.appending(path: "PrivilegedHelperTools"), nil),
            (roots.library.appending(path: "Receipts"), "old installer receipt")
        ]
        folders += [roots.userCache, roots.userTemp].compactMap { $0 }.map { ($0, "temporary files") }
        if let clones = roots.codeSigningClones {
            folders.append((clones, "code-signing copy"))
        }
        return folders
    }
}
