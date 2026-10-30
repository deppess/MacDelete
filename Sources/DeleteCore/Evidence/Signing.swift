import Foundation
import Security

public struct SigningInfo: Sendable, Equatable {
    public var teamIdentifier: String?
    /// `com.apple.security.application-groups`: the exact Group Containers folders the app uses.
    public var applicationGroups: [String]

    /// Reads the signature's metadata without validating it (~0.5 ms per third-party app; Apple's
    /// system apps are much slower, which is why callers skip them).
    public static func read(_ bundle: URL) -> SigningInfo? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = (entitlements?["com.apple.security.application-groups"] as? [String] ?? []).filter(isPlausibleGroup)
        return SigningInfo(teamIdentifier: (dictionary[kSecCodeInfoTeamIdentifier as String] as? String)?.nonEmpty, applicationGroups: groups)
    }

    /// Entitlements are data from the bundle; a group naming a path is ignored.
    private static func isPlausibleGroup(_ group: String) -> Bool {
        !group.isEmpty && !group.hasPrefix(".") && !group.contains("/") && group.count <= 255 && !group.unicodeScalars.contains { $0.value < 0x20 }
    }
}

/// Bundles inside an app that have identifiers of their own and leave their own containers,
/// preferences and launch items: app extensions, XPC services, system extensions, login-item
/// apps, and other helper apps. Sparkle's services are shared by every app that embeds Sparkle
/// and belong to none of them.
public enum EmbeddedBundles {
    public struct Embedded: Sendable, Equatable {
        public var identifier: String
        public var path: String
    }

    public static func find(in bundle: URL, mainIdentifier: String?, limit: Int = 256) -> [Embedded] {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        guard
            let enumerator = FileManager.default.enumerator(
                at: contents, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in true })
        else { return [] }
        // Folders that hold resources or code but never bundles of their own; skipping them keeps
        // a 4 GB app like Xcode from being walked file by file.
        let skipped: Set<String> = [
            "resources", "_codesignature", "headers", "privateheaders", "modules", "_masreceipt", "sharedsupport", "developer", "platforms"
        ]
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
        var found: [Embedded] = []
        var seen = Set<String>()
        if let main = mainIdentifier { seen.insert(main.lowercased()) }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent.lowercased()
            if name == "sharedsupport" {
                // Not walked (Xcode's holds tens of thousands of files), but apps directly in it
                // count: Office keeps its shared helpers there (Microsoft Error Reporting).
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                where child.pathExtension.lowercased() == "app" {
                    if let item = embedded(child, seen: &seen) { found.append(item) }
                }
                enumerator.skipDescendants()
                continue
            }
            if skipped.contains(name) || name.hasSuffix(".lproj") { enumerator.skipDescendants(); continue }
            guard bundleExtensions.contains(url.pathExtension.lowercased()), let item = embedded(url, seen: &seen) else { continue }
            found.append(item)
            if found.count >= limit { break }
        }
        return Array(found.prefix(limit))
    }

    private static func embedded(_ url: URL, seen: inout Set<String>) -> Embedded? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let plist = url.appending(path: "Contents/Info.plist")
        guard let metadata = SmallFile.plist(atPath: plist.path),
            let identifier = (metadata["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            isReverseDNS(identifier), !identifier.lowercased().hasPrefix("org.sparkle-project."),
            seen.insert(identifier.lowercased()).inserted
        else { return nil }
        return Embedded(identifier: identifier, path: url.path)
    }

    /// SMJobBless helper tools: plain executables in `Contents/Library/LaunchServices`, each named
    /// by the label it's installed under (`/Library/PrivilegedHelperTools/<label>`).
    public static func privilegedHelperLabels(in bundle: URL) -> [String] {
        let folder = bundle.appending(path: "Contents/Library/LaunchServices", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isReverseDNS).sorted()
    }

    static func isReverseDNS(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } && !identifier.contains("/")
            && identifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }
}
