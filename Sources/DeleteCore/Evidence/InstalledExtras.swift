import Foundation

/// Command-line tools an app put on the PATH as links into its bundle (`/usr/local/bin/code`,
/// `mpv`, `subl`). Left behind, each is a broken command. Only links count, judged by where they
/// really lead; a copied binary isn't evidence of anything.
enum CommandLinks {
    static func folders(roots: Roots) -> [URL] {
        let system = URL(filePath: roots.systemRoot, directoryHint: .isDirectory)
        return [system.appending(path: "usr/local/bin", directoryHint: .isDirectory)]
            + roots.homebrewPrefixes.map { $0.appending(path: "bin", directoryHint: .isDirectory) }
            + [roots.home.appending(path: ".local/bin", directoryHint: .isDirectory), roots.home.appending(path: "bin", directoryHint: .isDirectory)]
    }

    static func findings(bundlePath: String, roots: Roots, collector: inout Collector) -> [Finding] {
        guard let real = realpath(bundlePath, nil) else { return [] }
        let bundle = String(cString: real) + "/"
        free(real)
        var seen = Set<String>()
        var findings: [Finding] = []
        for folder in folders(roots: roots) where seen.insert(folder.standardizedFileURL.path).inserted {
            for name in collector.list(folder) {
                let link = folder.appending(path: name).path
                var info = stat()
                guard lstat(link, &info) == 0, info.st_mode & S_IFMT == S_IFLNK, let target = realpath(link, nil) else { continue }
                defer { free(target) }
                if String(cString: target).hasPrefix(bundle) { findings.append(Finding(path: link, tier: .exact, reason: "command-line link into the app")) }
            }
        }
        return findings
    }
}

/// Plug-ins an app installed into the Library, outside its bundle: QuickLook previews, Spotlight
/// importers, screen savers, preference panes, Services, audio plug-ins and drivers, virtual
/// cameras. Each is a bundle with its own identifier, so it's the app's exactly when that
/// identifier is (or is a sub-identifier of) one of the app's, by the same ownership rules as
/// every other item. One named after the app is name evidence only.
enum PluginBundles {
    static let folders = ["QuickLook", "Spotlight", "Screen Savers", "PreferencePanes", "Services", "Keyboard Layouts", "Frameworks", "ColorPickers", "Internet Plug-Ins",
                          "Contextual Menu Items", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/CLAP",
                          "Audio/MIDI Drivers", "CoreMediaIO/Plug-Ins/DAL"]

    static func scan(application: InstalledApp, ownership: Ownership, roots: Roots, collector: inout Collector) -> (findings: [Finding], skipped: [Skipped]) {
        let names = Set(([application.name] + application.alternateNames).map { $0.lowercased() })
        var findings: [Finding] = []
        var skipped: [Skipped] = []
        for library in [roots.home.appending(path: "Library", directoryHint: .isDirectory), roots.library] {
            for folderName in folders {
                let folder = library.appending(path: folderName, directoryHint: .isDirectory)
                for name in collector.list(folder) where !name.hasPrefix(".") {
                    let item = folder.appending(path: name)
                    let kind = description(of: folderName)
                    if let identifier = bundleIdentifier(of: item) {
                        switch ownership.owner(ofItemNamed: identifier) {
                        case .target?:
                            findings.append(Finding(path: item.path, tier: .exact, reason: kind))
                            continue
                        case let .shared(other)?, let .other(other)?:
                            if names.contains((name as NSString).deletingPathExtension.lowercased()) {
                                skipped.append(Skipped(path: item.path, reason: "\(kind) of \(Format.path(other, home: roots.home))"))
                            }
                            continue
                        case nil:
                            break
                        }
                    }
                    if names.contains((name as NSString).deletingPathExtension.lowercased()) {
                        findings.append(Finding(path: item.path, tier: .name, reason: "\(kind) named after the app"))
                    }
                }
            }
        }
        return (findings, skipped)
    }

    /// The bundle's own identifier, read without following links out of the folder.
    static func bundleIdentifier(of bundle: URL) -> String? {
        var info = stat()
        guard lstat(bundle.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        for relative in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
            let plist = bundle.appending(path: relative)
            var plistInfo = stat()
            guard lstat(plist.path, &plistInfo) == 0, plistInfo.st_mode & S_IFMT == S_IFREG, plistInfo.st_size <= 1_048_576,
                  let data = try? Data(contentsOf: plist),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            return (dictionary["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return nil
    }

    static func description(of folder: String) -> String {
        switch folder {
        case "QuickLook": "QuickLook plug-in"
        case "Spotlight": "Spotlight importer"
        case "Screen Savers": "screen saver"
        case "PreferencePanes": "settings pane"
        case "Services": "service"
        case "Keyboard Layouts": "keyboard layout"
        case "Frameworks": "framework"
        case "ColorPickers": "color picker"
        case "Internet Plug-Ins": "browser plug-in"
        case "Contextual Menu Items": "menu item plug-in"
        case "Audio/Plug-Ins/HAL": "audio driver"
        case "Audio/MIDI Drivers": "MIDI driver"
        case "CoreMediaIO/Plug-Ins/DAL": "camera plug-in"
        default: "audio plug-in"
        }
    }
}
