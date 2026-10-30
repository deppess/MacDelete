import Foundation

/// Leftovers a few apps keep outside the usual places, named by the app's own documentation.
/// Each rule applies only when no other installed app still uses the data.
enum AppSpecific {
    static func findings(for application: InstalledApp, others: [InstalledApp], roots: Roots) -> (findings: [Finding], skipped: [Skipped]) {
        let identifier = application.bundleIdentifier?.lowercased() ?? ""
        let otherIdentifiers = Set(others.compactMap { $0.bundleIdentifier?.lowercased() })
        let home = roots.home
        var findings: [Finding] = []
        var skipped: [Skipped] = []

        if identifier == "com.apple.dt.xcode" {
            // Regenerable build and device data. Archives, provisioning profiles, user data and
            // simulator devices are the user's and stay.
            let developer = home.appending(path: "Library/Developer", directoryHint: .isDirectory)
            let items =
                [
                    "Xcode/DerivedData", "Xcode/iOS DeviceSupport", "Xcode/macOS DeviceSupport", "Xcode/watchOS DeviceSupport", "Xcode/tvOS DeviceSupport",
                    "Xcode/xrOS DeviceSupport", "Xcode/visionOS DeviceSupport", "CoreSimulator/Caches"
                ].map { developer.appending(path: $0).path } + [home.appending(path: ".Xcode").path]
            for path in items where FileManager.default.fileExists(atPath: path) {
                if otherIdentifiers.contains("com.apple.dt.xcode") {
                    skipped.append(Skipped(path: path, reason: "another Xcode is still installed"))
                } else {
                    findings.append(Finding(path: path, tier: .exact, reason: "Xcode build data"))
                }
            }
        }

        // GarageBand, Logic Pro and MainStage share their downloaded sound libraries.
        let music = ["com.apple.garageband", "com.apple.logic", "com.apple.mainstage"]
        if music.contains(where: identifier.hasPrefix) {
            let survivor = others.first { other in music.contains { (other.bundleIdentifier?.lowercased() ?? "").hasPrefix($0) } }
            let libraries = [("Application Support/GarageBand", EvidenceTier.exact), ("Application Support/Logic", .exact), ("Audio/Apple Loops", .name)]
            for (relative, tier) in libraries {
                let path = roots.library.appending(path: relative).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let survivor {
                    skipped.append(Skipped(path: path, reason: "sound library still used by \(survivor.name)"))
                } else {
                    findings.append(Finding(path: path, tier: tier, reason: tier == .exact ? "sound library" : "sound library other music apps can use too"))
                }
            }
        }
        return (findings, skipped)
    }
}
