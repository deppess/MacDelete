import Foundation

/// Browser native-messaging host manifests (`<name>.json`) whose `path` runs a program inside the
/// app: KeePassXC registers one with every browser it finds. The manifest is only a pointer, so
/// a browser left with it shows a broken extension.
enum NativeMessaging {
    /// Chrome-family browsers keep the folder in their own Application Support folder, some a level
    /// deeper (`Google/Chrome`, `BraveSoftware/Brave-Browser`, `Arc/User Data`); Firefox-family
    /// ones under `Mozilla` or their own name. System-wide manifests live in /Library.
    static func folders(roots: Roots, collector: inout Collector) -> [URL] {
        var folders: [URL] = []
        for support in [roots.home.appending(path: "Library/Application Support", directoryHint: .isDirectory), roots.library.appending(path: "Application Support", directoryHint: .isDirectory)] {
            for name in collector.list(support) where !name.hasPrefix(".") && !name.lowercased().hasPrefix("com.apple.") {
                let entry = support.appending(path: name, directoryHint: .isDirectory)
                folders += [entry.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory), entry.appending(path: "User Data/NativeMessagingHosts", directoryHint: .isDirectory)]
                if vendorFolders.contains(name.lowercased()) {
                    for child in collector.list(entry) where !child.hasPrefix(".") {
                        folders.append(entry.appending(path: "\(child)/NativeMessagingHosts", directoryHint: .isDirectory))
                    }
                }
            }
        }
        folders += ["Google/Chrome", "Microsoft/Edge", "Chromium"].map { roots.library.appending(path: "\($0)/NativeMessagingHosts", directoryHint: .isDirectory) }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Folders holding one subfolder per browser.
    static let vendorFolders: Set<String> = ["google", "bravesoftware", "microsoft", "yandex", "naver", "opera software"]

    static func findings(bundlePath: String, roots: Roots, collector: inout Collector) -> [Finding] {
        let bundle = bundlePath.lowercased() + "/"
        var findings: [Finding] = []
        for folder in folders(roots: roots, collector: &collector) {
            for name in collector.list(folder) where name.lowercased().hasSuffix(".json") {
                let manifest = folder.appending(path: name)
                guard let program = program(in: manifest), program.lowercased().hasPrefix(bundle) else { continue }
                findings.append(Finding(path: manifest.path, tier: .exact, reason: "browser native messaging host"))
            }
        }
        return findings
    }

    /// The manifest's `path`, normalized so `..` can't step out of the bundle.
    static func program(in manifest: URL) -> String? {
        var info = stat()
        guard lstat(manifest.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576,
              let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String, path.hasPrefix("/") else { return nil }
        return URL(filePath: path).standardizedFileURL.path
    }
}
