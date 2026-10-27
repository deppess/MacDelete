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
    /// The app's identifiers, lowercased, as bytes.
    private let targetPrefixes: [[UInt8]]

    /// `otherEmbedded` are identifiers embedded in other installed apps (helpers several apps of a
    /// suite each carry, like Office's `com.microsoft.errorreporting`), with the app carrying them.
    init(targetPath: String, targetIdentifiers: [String], otherApplications: [InstalledApp], otherEmbedded: [(identifier: String, path: String)] = []) {
        self.targetPath = targetPath
        targetPrefixes = targetIdentifiers.map { Array($0.lowercased().utf8) }
        for identifier in targetIdentifiers { claims[identifier.lowercased(), default: []].insert(targetPath) }
        for application in otherApplications where application.bundlePath != targetPath {
            if let identifier = application.bundleIdentifier { claims[identifier.lowercased(), default: []].insert(application.path) }
        }
        for (identifier, path) in otherEmbedded where path != targetPath { claims[identifier.lowercased(), default: []].insert(path) }
    }

    /// Whether an item with this name can belong to the app at all: every identifier that
    /// could name it for the app starts it. A byte comparison, ignoring ASCII case, that rules
    /// out nearly every entry of a folder (the per-user temp folder holds ~12,000) before
    /// `owner(ofItemNamed:)` builds any string.
    func mightBelongToTarget(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { bytes in
            targetPrefixes.contains { prefix in
                guard bytes.count >= prefix.count else { return false }
                for index in prefix.indices {
                    let byte = bytes[index]
                    if (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) != prefix[index] { return false }
                }
                return true
            }
        }
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
        // (Dots are counted rather than the name split: this runs for every entry of every folder.)
        var candidate = Substring(lowered)
        var dots = lowered.reduce(0) { $1 == "." ? $0 + 1 : $0 }
        while dots >= 3, let dot = candidate.lastIndex(of: ".") {
            candidate = candidate[..<dot]
            dots -= 1
            if let apps = claims[String(candidate)] { return owner(apps) }
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
