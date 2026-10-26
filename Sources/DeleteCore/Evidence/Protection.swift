import Foundation

/// What may never be deleted. The removable-Apple-app and security-vendor lists are adapted from
/// Mole (github.com/tw93/Mole, GPL-3.0), `lib/core/app_protection_data.sh`.
public enum Protection {
    /// Apple apps installed into /Applications (mostly from the App Store) that a user may remove.
    /// Everything else from Apple is part of macOS.
    static let removableApplePatterns = [
        "com.apple.dt.*", // Xcode, Instruments, FileMerge, …
        "com.apple.FinalCut*", "com.apple.Motion", "com.apple.Compressor",
        "com.apple.logic*", "com.apple.garageband*", "com.apple.MainStage*",
        "com.apple.iMovie", "com.apple.iWork.*", "com.apple.server.*", "com.apple.Playgrounds",
        "com.apple.configurator.*", "com.apple.TestFlight", "com.apple.Transporter",
    ]

    /// Security and device-management agents. Removing their files by hand trips tamper
    /// detection and leaves the machine half-managed; they come with their own uninstallers.
    static let securityVendors: [(name: String, prefixes: [String])] = [
        ("ESET", ["com.eset."]),
        ("Jamf", ["com.jamf.", "com.jamfsoftware."]),
        ("CrowdStrike", ["com.crowdstrike."]),
        ("SentinelOne", ["com.sentinelone.", "com.sentinel-labs."]),
        ("GlobalProtect", ["com.paloaltonetworks."]),
        ("Cisco Secure Client", ["com.cisco.anyconnect", "com.cisco.secureclient"]),
        ("Alibaba Cloud Security", ["com.alibaba.security."]),
        ("Microsoft Defender", ["com.microsoft.wdav"]),
        ("Kandji", ["io.kandji."]),
        ("Mosyle", ["com.mosyle."]),
    ]

    /// Why `application` can't be deleted, or nil when it can.
    public static func refusal(for application: InstalledApp) -> Refusal? {
        let name = application.name.terminalInline
        if application.classification == .system || application.path.hasPrefix("/System/") || application.bundlePath.hasPrefix("/System/") {
            return Refusal(message: "\(name) is part of macOS and can't be deleted.")
        }
        let identifier = application.bundleIdentifier ?? ""
        if identifier.lowercased().hasPrefix("com.apple.") {
            let removable = removableApplePatterns.contains { glob($0.lowercased(), matches: identifier.lowercased()) }
            if !removable || application.path != application.bundlePath {
                return Refusal(message: "\(name) is part of macOS and can't be deleted.")
            }
        }
        // MacPorts tracks its files itself; removing them by hand leaves it believing the port is
        // installed (refused until the user decides otherwise, 2026-10-26).
        if application.source == .macPorts || application.bundlePath.hasPrefix("/Applications/MacPorts/") {
            return Refusal(message: "\(name) was installed by MacPorts. Remove it with \"sudo port uninstall <port>\" (\"port provides \(Format.shellQuoted(application.bundlePath + "/Contents/Info.plist").terminalInline)\" names the port).")
        }
        if let vendor = securityVendors.first(where: { $0.prefixes.contains { identifier.lowercased().hasPrefix($0.lowercased()) } }) {
            return Refusal(message: "\(name) is \(vendor.name) security or management software. Use \(vendor.name)'s own uninstaller; removing its files by hand can trigger tamper alerts.")
        }
        return nil
    }

    /// Paths delete never removes, whatever matched them: the user's own documents and shared
    /// data, system locations, and the standard folders themselves.
    /// Checked against the injected roots (tests, the sandbox) and always against the real system's
    /// own folders too, so a path from outside the roots (a zap list naming "/Applications") is
    /// still protected.
    public static func isProtected(_ path: String, roots: Roots) -> Bool {
        let homePath = roots.home.standardizedFileURL.path
        let root = roots.systemRoot == "/" ? "" : roots.systemRoot
        return isProtected(path, homePath: homePath, libraryPath: roots.library.standardizedFileURL.path, root: root)
            || (!root.isEmpty && isProtected(path, homePath: homePath, libraryPath: "/Library", root: ""))
    }

    private static func isProtected(_ path: String, homePath: String, libraryPath: String, root: String) -> Bool {
        let path = URL(filePath: path).standardizedFileURL.path
        let lowered = path.lowercased()
        // /System is protected wherever the injected root is.
        if lowered == "/system" || lowered.hasPrefix("/system/") { return true }

        let neverInside = [
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/private/var/db", "/Library/Apple",
        ].map { root + $0 } + [
            "\(homePath)/Documents", "\(homePath)/Desktop", "\(homePath)/Downloads", "\(homePath)/Music", "\(homePath)/Movies",
            "\(homePath)/Pictures", "\(homePath)/Public", "\(homePath)/Library/Mobile Documents", "\(homePath)/Library/CloudStorage",
            "\(homePath)/Library/Keychains", "\(homePath)/Library/Mail", "\(homePath)/Library/Messages", "\(homePath)/.ssh", "\(homePath)/.gnupg",
            // Steam's folder holds the whole game library; Unity's and Epic's are shared by every
            // game and editor built on them.
            "\(homePath)/Library/Application Support/Steam", "\(homePath)/Library/Unity", "\(homePath)/Library/Application Support/Epic",
        ]
        // Vendor folders several products share: only items inside them, never the folder.
        let sharedVendorFolders = ["Google", "Microsoft", "Adobe", "Application Support/Google", "Application Support/Microsoft", "Application Support/Adobe",
                                   "Application Support/JetBrains", "Caches/Google", "Caches/Microsoft", "Caches/Adobe", "Caches/JetBrains", "Logs/JetBrains"]
        if sharedVendorFolders.contains(where: { lowered == "\(homePath)/Library/\($0)".lowercased() || lowered == "\(libraryPath)/\($0)".lowercased() }) { return true }
        if neverInside.contains(where: { lowered == $0.lowercased() || lowered.hasPrefix($0.lowercased() + "/") }) { return true }

        // The folders themselves, never their contents.
        let never = ["/", "/Applications", "/Users", "/Users/Shared", "/usr", "/usr/local", "/usr/local/bin", "/opt", "/private", "/private/var", "/private/tmp", "/var", "/tmp", "/etc"].map { root + $0 } + [
                     homePath, "\(homePath)/Applications", "\(homePath)/Library", "\(homePath)/.config", "\(homePath)/.local", "\(homePath)/.local/share", "\(homePath)/.cache", libraryPath]
        if never.contains(where: { lowered == $0.lowercased() }) { return true }
        // Standard Library folders (Caches, Preferences, …) and their well-known subfolders.
        for base in ["\(homePath)/Library", libraryPath] {
            let prefix = base.lowercased() + "/"
            guard lowered.hasPrefix(prefix) else { continue }
            let rest = lowered.dropFirst(prefix.count).split(separator: "/")
            if rest.count == 1, standardLibraryFolders.contains(String(rest[0])) || rest[0].hasPrefix("com.apple.") { return true }
            if rest.count == 2, ["preferences/byhost", "audio/plug-ins", "application support/crashreporter", "caches/sentrycrash", "logs/diagnosticreports",
                                  "application support/com.apple.sharedfilelist", "caches/com.plausiblelabs.crashreporter.data"].contains(rest.joined(separator: "/")) { return true }
            if rest.count == 3, rest.joined(separator: "/") == "application support/com.apple.sharedfilelist/com.apple.lsSharedFileList.ApplicationRecentDocuments".lowercased() { return true }
        }
        return false
    }

    /// Folders macOS keeps directly in ~/Library and /Library. Lowercased.
    static let standardLibraryFolders: Set<String> = Set([
        "Accessibility", "Accounts", "Application Scripts", "Application Support", "Apple", "Assistant", "Assistants", "Audio", "Autosave Information", "Biome",
        "Bundles", "Caches", "Calendars", "CallServices", "CloudStorage", "ColorPickers", "ColorSync", "Colors", "Components", "Compositions", "ContainerManager",
        "Containers", "Contextual Menu Items", "Cookies", "CoreData", "CoreFollowUp", "CoreMediaIO", "CoreServices", "Daemon Containers", "DataAccess",
        "DataDeliveryServices", "Desktop Pictures", "Developer", "Dictionaries", "DirectoryServices", "DoNotDisturb", "Documentation", "DriverExtensions",
        "DuetExpertCenter", "Extensions", "Favorites", "Filesystems", "FontCollections", "Fonts", "Frameworks", "GameKit", "Graphics", "Group Containers",
        "HTTPStorages", "HomeKit", "IdentityServices", "Image Capture", "Input Methods", "IntelligencePlatform", "Internet Plug-Ins", "Java", "Keyboard",
        "Keyboard Layouts", "KeyboardServices", "Keychains", "LanguageModeling", "LaunchAgents", "LaunchDaemons", "LockdownMode", "Logs", "Mail", "Messages",
        "Metadata", "Mobile Documents", "Modem Scripts", "OSAnalytics", "PDF Services", "Passes", "Perl", "PersonalizationPortrait", "Photos", "PreferencePanes",
        "Preferences", "Printers", "PrivilegedHelperTools", "Python", "QuickLook", "Receipts", "Reminders", "ResponseKit", "Ruby", "Safari", "SafariSafeBrowsing",
        "Sandbox", "Saved Application State", "Screen Savers", "ScreenRecordings", "Scripts", "Security", "Services", "Sharing", "Shortcuts", "Sounds",
        "Speech", "Spelling", "Spotlight", "StartupItems", "StatusKit", "Suggestions", "SyncedPreferences", "SystemExtensions", "SystemMigration", "Translation",
        "Trial", "Updates", "User Pictures", "Video", "Weather", "WebKit", "WebServer", "Widgets", "Workflows",
    ].map { $0.lowercased() })

    /// Shell-style `*` matching on whole identifiers.
    static func glob(_ pattern: String, matches value: String) -> Bool {
        fnmatch(pattern, value, 0) == 0
    }
}
