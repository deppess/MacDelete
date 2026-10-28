import Foundation

public enum AppClassification: String, Sendable, Codable {
    /// In /Applications, ~/Applications, or a Steam library: what `delete list` shows.
    case user
    /// Part of macOS: /System, CoreServices, a Cryptex. Never deleted.
    case system
    /// Any other bundle Spotlight found (helpers in Application Support, build products).
    /// Hidden from `list`, but `delete <path>` accepts it.
    case auxiliary
}

public enum AppSource: Sendable, Equatable, Codable {
    case appStore
    /// `declared`: the app is one of the cask's own artifacts and is eligible for delete's bounded
    /// local replication. Otherwise it only links into the cask's Caskroom folder.
    case homebrew(token: String, declared: Bool)
    case macPorts
    case installerPackage(identifiers: [String])
    case steam
    case setapp
    case macOS
    case download

    public var label: String {
        switch self {
        case .appStore: "App Store"
        case let .homebrew(token, _): "Homebrew (\(token))"
        case .macPorts: "MacPorts"
        case .installerPackage: "Installer package"
        case .steam: "Steam"
        case .setapp: "Setapp"
        case .macOS: "macOS"
        case .download: "Download"
        }
    }
}

public struct InstalledApp: Sendable {
    /// Where the app is, as the scan found it; may be a symlink (Safari in /Applications).
    public var path: String
    /// The real bundle directory, when `path` is a link.
    public var bundlePath: String
    /// The bundle's file name without `.app`, as Finder shows it.
    public var name: String
    public var bundleIdentifier: String?
    /// CFBundleDisplayName and CFBundleName, when they differ from `name`; also accepted when matching.
    public var alternateNames: [String]
    public var version: String?
    public var executableName: String?
    public var classification: AppClassification
    public var source: AppSource
    /// Allocated size in bytes, from Spotlight or a walk of the bundle.
    public var size: Int64?
    /// Where the bundle or its executable really lives, when either is a link (Homebrew's Caskroom).
    public var linkTargets: [String]
    /// Has `Contents/_MASReceipt/receipt`, or is an iOS app wrapper.
    public var hasAppStoreReceipt: Bool
    /// An iPhone or iPad app running on Apple Silicon (`Wrapper/` + `WrappedBundle`).
    public var isIOSApp: Bool
    /// A Steam "desktop shortcut" with no identifier that runs `open steam://run/<id>`.
    public var isSteamShortcut: Bool
}
