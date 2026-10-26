import Foundation

public enum EvidenceTier: String, Sendable, Codable {
    /// Named by the app's identifier, its entitlements, its receipt, or its own launch item:
    /// selected by default.
    case exact
    /// Matched only by the app's name: shown, selected only with --include-name-matches.
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
    /// Homebrew removes the app first (`brew uninstall --cask <token>`); the rest, its zap list
    /// included, is deleted permanently by delete.
    public var homebrewCask: String?

    public func selected(includeNameMatches: Bool) -> [Finding] {
        findings.filter { $0.tier == .exact || includeNameMatches }
    }
}

/// Why an app can't be deleted at all.
public struct Refusal: Error, Sendable, Equatable {
    public var message: String
}
