import CryptoKit
import Foundation

public enum EvidenceTier: String, Sendable, Codable {
    /// Named by the app's identifier, its entitlements, its receipt, or its own launch item.
    case exact
    /// Matched only by the app's name: lower-confidence evidence, but included in the displayed
    /// and confirmed deletion plan.
    case name
}

/// One item that belongs to the app.
public struct Finding: Sendable, Equatable {
    public var path: String
    public var tier: EvidenceTier
    /// Why it belongs to the app, when that isn't simply its bundle identifier.
    public var reason: String?
    public var size: Int64 = 0
    /// False when part of it couldn't be read, so `size` is a lower bound.
    public var sizeComplete = true
    /// Owned by another user (root) or inside a folder this user can't change.
    public var needsRoot = false
    /// A symbolic link (a command-line link): removing it removes only the link.
    public var isLink = false

    public init(path: String, tier: EvidenceTier, reason: String? = nil) {
        self.path = path
        self.tier = tier
        self.reason = reason
    }
}

/// An item that looked like the app's but is left alone, and why.
public struct Skipped: Sendable, Equatable {
    public var path: String
    public var reason: String
}

/// A launchd job that belongs to the app; it's stopped (`launchctl bootout`) before deletion.
public struct LaunchItem: Sendable, Equatable {
    public enum Domain: String, Sendable { case user, system }
    public var label: String
    public var plist: String
    public var domain: Domain
}

/// Everything known about removing one app.
public struct RemovalPlan: Sendable {
    public var application: InstalledApp
    public var identifiers: [String]
    public var findings: [Finding]
    public var skipped: [Skipped]
    public var launchItems: [LaunchItem]
    /// Installer-package receipts to forget (`pkgutil --forget`, needs root).
    public var packages: [String]
    /// Folders that couldn't be read, so the plan may be incomplete.
    public var unreadable: [String]
    public var notes: [String]
    /// System extensions of the app that are active; deleting the app doesn't remove them.
    public var activeSystemExtensions: [String] = []
    public var running: Bool
    /// The installed Homebrew cask whose declarative artifacts this plan reproduces locally.
    public var homebrewCask: String?
    /// Folders the cask's zap list names with `rmdir`: removed at the end only if nothing is left
    /// in them (a `.DS_Store` aside), never with their contents.
    public var emptyFolders: [String] = []

    /// Every displayed finding is part of the one confirmed deletion plan. `tier` still records
    /// whether the evidence is exact or name-derived, so callers can render the distinction.
    public func selected() -> [Finding] { findings }

    /// The app's own bundle (or a Steam game's folder): deleted first, and the run stops if it can't be.
    public func isOwn(_ finding: Finding) -> Bool {
        let lowered = finding.path.lowercased()
        return lowered == application.path.lowercased() || lowered == application.bundlePath.lowercased() || finding.reason == "Steam game folder"
    }

    /// True when the app itself needs administrator rights this run doesn't have. Then nothing is
    /// deleted: removing its data while the app stays would only break it.
    public func appNeedsRoot(isRoot: Bool) -> Bool {
        !isRoot && findings.contains { isOwn($0) && $0.needsRoot }
    }

    /// What this run deletes, and what it leaves for `sudo`.
    public func split(isRoot: Bool) -> (deleting: [Finding], needingRoot: [Finding]) {
        let selected = selected()
        if isRoot { return (selected, []) }
        if appNeedsRoot(isRoot: isRoot) { return ([], selected) }
        return (selected.filter { !$0.needsRoot }, selected.filter(\.needsRoot))
    }

    /// Whether deleting it needs administrator rights: an item, a receipt, or a system launch item.
    public func needsRoot() -> Bool {
        !split(isRoot: false).needingRoot.isEmpty || !packages.isEmpty || launchItems.contains { $0.domain == .system }
    }

    /// An app's plan and its companions' with every item, receipt and launch item in only one of
    /// them: in the plan whose own bundle holds it, otherwise the first that names it (or a
    /// folder holding it).
    public static func deduplicated(_ plans: [RemovalPlan]) -> [RemovalPlan] {
        let bundles = plans.map { [$0.application.path, $0.application.bundlePath].map { $0.lowercased() } }
        func isInside(_ path: String, _ other: String) -> Bool { path == other || path.hasPrefix(other + "/") }
        var result: [RemovalPlan] = []
        var taken: [String] = [], packages = Set<String>(), launchItems = Set<String>(), emptyFolders = Set<String>()
        for (index, var plan) in plans.enumerated() {
            plan.findings = plan.findings.filter { finding in
                let lowered = finding.path.lowercased()
                let ownedElsewhere = bundles.indices.contains { $0 != index && bundles[$0].contains { isInside(lowered, $0) } }
                return !ownedElsewhere && !taken.contains { isInside(lowered, $0) }
            }
            taken += plan.findings.map { $0.path.lowercased() }
            plan.packages = plan.packages.filter { packages.insert($0.lowercased()).inserted }
            plan.launchItems = plan.launchItems.filter { launchItems.insert($0.plist.lowercased()).inserted }
            plan.emptyFolders = plan.emptyFolders.filter { emptyFolders.insert($0.lowercased()).inserted }
            result.append(plan)
        }
        return result
    }

    /// What a group of plans deletes, as one short fingerprint: delete, rerun under sudo, deletes
    /// without asking again only when its plans have the one that was confirmed.
    /// `identities` is captured after the final plan and before confirmation. It binds a sudo
    /// rerun to the exact filesystem objects, ownership and modes the user reviewed.
    public static func fingerprint(_ plans: [RemovalPlan], identities: [String: FileIdentity] = [:]) -> String {
        var encoder = ApprovalFingerprintEncoder()
        encoder.string("macdelete.approval-fingerprint")
        encoder.integer(1)
        encoder.integer(plans.count)
        for plan in plans {
            encoder.string(plan.application.path)
            encoder.strings(plan.selected().map(\.path).sorted())
            encoder.strings(plan.packages.sorted())
            encoder.strings(plan.launchItems.map(\.plist).sorted())
            encoder.strings(plan.emptyFolders.sorted())
            encoder.optionalString(plan.homebrewCask)
        }
        encoder.integer(identities.count)
        for (key, identity) in identities.sorted(by: { $0.key < $1.key }) {
            encoder.string(key)
            encoder.integer(identity.device)
            encoder.integer(identity.inode)
            encoder.integer(identity.type)
            encoder.integer(identity.owner)
            encoder.integer(identity.group)
            encoder.integer(identity.permissions)
        }
        // This crosses a privilege boundary, so use a collision-resistant digest rather than a
        // compact non-cryptographic checksum. It is still not a secret or an authorization token.
        return SHA256.hash(data: encoder.data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Canonical length-prefixed encoding for data bound to the sudo approval fingerprint.
private struct ApprovalFingerprintEncoder {
    private(set) var data = Data()

    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var encoded = UInt64(truncatingIfNeeded: value).bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        integer(bytes.count)
        data.append(bytes)
    }

    mutating func optionalString(_ value: String?) {
        integer(value == nil ? 0 : 1)
        if let value { string(value) }
    }

    mutating func strings(_ values: [String]) {
        integer(values.count)
        values.forEach { string($0) }
    }
}

/// Why an app can't be deleted at all.
public struct Refusal: Error, Sendable, Equatable {
    public var message: String
}
