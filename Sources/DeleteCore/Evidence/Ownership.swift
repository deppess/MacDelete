import Foundation

/// Decides which installed app an item named by a bundle identifier belongs to.
///
/// An item belongs to the most specific installed identifier it's named by: the identifier
/// itself (`com.raycast.macos`), or followed by a dot and anything (`com.raycast.macos.plist`,
/// `com.raycast.macos.BrowserExtension`, `com.raycast.macos.<hardware UUID>.plist`). So with both
/// `com.foo.app` and `com.foo.app.pro` installed, `com.foo.app.pro.plist` is Pro's. When two
/// installed apps share that identifier (Xcode and Xcode-beta), the item is shared and kept.
/// Comparisons ignore case: KeePassXC is `org.keepassxc.keepassxc`, its launch agent
/// `org.keepassxc.KeePassXC`.
struct Ownership {
    enum Owner: Equatable {
        case target
        case other(String)
        case shared(String)
    }

    /// Lowercased identifier → the apps (paths) that carry it.
    private var claims: [String: Set<String>] = [:]
    private let targetPath: String

    /// `otherEmbedded` are identifiers embedded in other installed apps (helpers several apps of a
    /// suite each carry, like Office's `com.microsoft.errorreporting`), with the app carrying them.
    init(targetPath: String, targetIdentifiers: [String], otherApplications: [InstalledApp], otherEmbedded: [(identifier: String, path: String)] = []) {
        self.targetPath = targetPath
        for identifier in targetIdentifiers { claims[identifier.lowercased(), default: []].insert(targetPath) }
        for application in otherApplications where application.bundlePath != targetPath {
            if let identifier = application.bundleIdentifier { claims[identifier.lowercased(), default: []].insert(application.path) }
        }
        for (identifier, path) in otherEmbedded where path != targetPath { claims[identifier.lowercased(), default: []].insert(path) }
    }

    /// The owner of an item with this file name, or nil when no installed identifier names it.
    func owner(ofItemNamed name: String) -> Owner? {
        let lowered = name.lowercased()
        // The whole name, or the name without the suffix its folder adds (`<id>.plist`).
        for whole in [lowered] + Self.suffixes.filter(lowered.hasSuffix).map({ String(lowered.dropLast($0.count)) }) {
            if let apps = claims[whole] { return owner(apps) }
        }
        // Otherwise the longest identifier followed by a dot. A bare prefix needs at least three
        // components, so a two-part identifier like `com.example` never claims its whole vendor.
        var candidate = Substring(lowered)
        while let dot = candidate.lastIndex(of: ".") {
            candidate = candidate[..<dot]
            if candidate.split(separator: ".").count >= 3, let apps = claims[String(candidate)] { return owner(apps) }
        }
        return nil
    }

    private func owner(_ apps: Set<String>) -> Owner {
        if apps == [targetPath] { return .target }
        if apps.contains(targetPath) { return .shared(apps.subtracting([targetPath]).sorted().first ?? "") }
        return .other(apps.sorted().first ?? "")
    }

    private static let suffixes = [".plist", ".savedstate", ".binarycookies", ".sfl2", ".sfl3", ".sfl4", ".app", ".bom", ".shipit", ".code_sign_clone"]
}
