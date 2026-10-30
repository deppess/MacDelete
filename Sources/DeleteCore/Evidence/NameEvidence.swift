import Foundation

/// Name evidence: lower-confidence items named only after the app. They remain visibly
/// distinguished in the plan, but are included in its single confirmed deletion set.
extension EvidenceFinder {
    func nameFindings(_ application: InstalledApp, others: [InstalledApp], collector: inout Collector) -> [Finding] {
        let otherNames = Set(others.flatMap { [$0.name] + $0.alternateNames + [$0.executableName].compactMap { $0 } }.map { $0.lowercased() })
        // The app's names, plus each without a trailing version or letter ("CleanShot X" keeps
        // its data in "CleanShot", "FL Studio 2026" in "FL Studio").
        var candidates = [application.name] + application.alternateNames + [application.executableName].compactMap { $0 }
        for name in candidates {
            let words = name.split(separator: " ")
            if words.count > 1, let last = words.last, last.count == 1 || last.allSatisfy(\.isNumber) {
                candidates.append(words.dropLast().joined(separator: " "))
            }
        }
        let names = Self.distinct(candidates)
            .filter { $0.count >= 3 && !Self.commonWords.contains($0.lowercased()) && !otherNames.contains($0.lowercased()) }
        guard !names.isEmpty else { return [] }
        let lowerNames = Set(names.map { $0.lowercased() })
        let library = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        var findings: [Finding] = []

        /// The name itself, or followed by a version ("iStat Menus 7").
        func isNamed(_ entry: String) -> Bool {
            let lowered = entry.lowercased()
            if lowerNames.contains(lowered) { return true }
            guard let space = lowered.lastIndex(of: " ") else { return false }
            let version = lowered[lowered.index(after: space)...]
            return !version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." } && lowerNames.contains(String(lowered[..<space]))
        }
        for folder in ["Application Support", "Caches", "Logs", "Caches/SentryCrash"].map({ library.appending(path: $0, directoryHint: .isDirectory) }) {
            for name in collector.list(folder)
            where isNamed(name) || (folder.lastPathComponent == "Logs" && name.lowercased().hasSuffix(".log") && isNamed(String(name.dropLast(4)))) {
                findings.append(Finding(path: folder.appending(path: name).path, tier: .name, reason: "named after the app"))
            }
        }
        let preferences = library.appending(path: "Preferences", directoryHint: .isDirectory)
        for name in collector.list(preferences) {
            let lowered = name.lowercased()
            if lowered.hasSuffix(".plist") {
                let base = String(name.dropLast(6))
                if !base.contains("."), isNamed(base) {
                    findings.append(Finding(path: preferences.appending(path: name).path, tier: .name, reason: "named after the app"))
                }
            } else if let suffix = [" settings", " prefs", " preferences"].first(where: lowered.hasSuffix), isNamed(String(name.dropLast(suffix.count))) {
                // Adobe's shape: ~/Library/Preferences/Adobe Photoshop 2026 Settings.
                findings.append(Finding(path: preferences.appending(path: name).path, tier: .name, reason: "the app's settings"))
            }
        }
        let config = roots.home.appending(path: ".config", directoryHint: .isDirectory)
        let dotNames = Set(lowerNames.flatMap { [$0, $0.replacingOccurrences(of: " ", with: ""), $0.replacingOccurrences(of: " ", with: "-")] })
        for name in collector.list(config) where dotNames.contains(name.lowercased()) {
            findings.append(Finding(path: config.appending(path: name).path, tier: .name, reason: "named after the app"))
        }
        for name in collector.list(roots.home) where name.hasPrefix(".") && dotNames.contains(String(name.dropFirst()).lowercased()) {
            findings.append(Finding(path: roots.home.appending(path: name).path, tier: .name, reason: "named after the app"))
        }
        // Cross-platform apps sometimes keep a workspace beside the hidden configuration folder
        // (for example ~/logseq next to ~/.logseq). It can be the user's actual documents, so
        // show an unambiguous same-named home-folder with an explicit user-data warning.
        for name in collector.list(roots.home) where !name.hasPrefix(".") && isNamed(name) {
            let item = roots.home.appending(path: name)
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            findings.append(Finding(path: item.path, tier: .name, reason: "named after the app; may hold your own files"))
        }
        // XDG folders that command-line and cross-platform apps use (~/.local/share/mimi).
        for folder in [".local/share", ".local/state", ".cache"].map({ roots.home.appending(path: $0, directoryHint: .isDirectory) }) {
            for name in collector.list(folder) where dotNames.contains(name.lowercased()) {
                findings.append(Finding(path: folder.appending(path: name).path, tier: .name, reason: "named after the app"))
            }
        }
        // Some desktop apps install a separate user command in ~/.local/bin or ~/bin. A regular
        // executable with the app's unambiguous name is useful evidence, but not proof that it
        // came from the bundle (unlike CommandLinks above), so the plan labels it as name-derived.
        // Do not include arbitrary files or a same-named symlink: the former is not a command and
        // the latter is handled as exact evidence only when it resolves into this app.
        for folder in [".local/bin", "bin"].map({ roots.home.appending(path: $0, directoryHint: .isDirectory) }) {
            for name in collector.list(folder) where isNamed(name) {
                let executable = folder.appending(path: name)
                guard isRegularExecutable(executable) else { continue }
                findings.append(Finding(path: executable.path, tier: .name, reason: "command-line executable named after the app"))
            }
        }
        // The system-wide counterparts, and the folder every user of the Mac shares.
        for folder in ["Application Support", "Caches", "Logs"].map({ roots.library.appending(path: $0, directoryHint: .isDirectory) }) + [roots.sharedUsers] {
            for name in collector.list(folder) where isNamed(name) {
                findings.append(
                    Finding(
                        path: folder.appending(path: name).path, tier: .name,
                        reason: folder == roots.sharedUsers ? "named after the app, shared by all users" : "named after the app"))
            }
        }
        // Help Viewer's copy of the app's help book, by its title ("CleanShot X Help*2.0").
        let help = library.appending(path: "Caches/com.apple.helpd/Generated", directoryHint: .isDirectory)
        for name in collector.list(help) {
            let lowered = name.lowercased()
            if lowerNames.contains(where: { lowered == "\($0) help" || lowered.hasPrefix("\($0) help*") }) {
                findings.append(Finding(path: help.appending(path: name).path, tier: .name, reason: "help cache"))
            }
        }
        findings += vendorFolderFindings(application, others: others, collector: &collector)
        if let executable = application.executableName?.lowercased(), executable.count >= 3, !otherNames.contains(executable) {
            for reports in [library, roots.library].map({ $0.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory) }) {
                for name in collector.list(reports) {
                    let lowered = name.lowercased()
                    guard lowered.hasPrefix(executable + "-") || lowered.hasPrefix(executable + "_") || lowered.hasPrefix(executable + "."),
                        [".ips", ".crash", ".diag", ".spin", ".hang"].contains(where: lowered.hasSuffix)
                    else { continue }
                    findings.append(Finding(path: reports.appending(path: name).path, tier: .name, reason: "crash report"))
                }
            }
            let crashReporter = library.appending(path: "Application Support/CrashReporter", directoryHint: .isDirectory)
            for name in collector.list(crashReporter) where name.lowercased().hasPrefix(executable + "_") && name.lowercased().hasSuffix(".plist") {
                findings.append(Finding(path: crashReporter.appending(path: name).path, tier: .name, reason: "crash reporter state"))
            }
        }
        return findings
    }

    /// Products inside a vendor's folder: `JetBrains/IntelliJIdea2026.2`, `Google/Chrome`,
    /// `BraveSoftware/Brave-Browser`. The vendor is the second part of the bundle identifier
    /// (`com.jetbrains.intellij`), matched to a folder by name or prefix ("brave" →
    /// "BraveSoftware"). Inside it, a product folder named after the app (whole, without the
    /// vendor's word, hyphenated or squeezed, optionally followed by a version) is name evidence.
    /// The vendor folder itself never is: other products of the vendor may live there.
    func vendorFolderFindings(_ application: InstalledApp, others: [InstalledApp], collector: inout Collector) -> [Finding] {
        guard let identifier = application.bundleIdentifier?.lowercased() else { return [] }
        let parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 3, ["com", "org", "net", "io", "de", "co", "app", "dev", "me", "ch", "at", "fr", "uk", "jp", "ru", "cn"].contains(parts[0]) else {
            return []
        }
        let vendor = parts[1]
        guard vendor.count >= 3,
            !["apple", "github", "electron", "google.code", "example", "company", "mycompany", "yourcompany", "defaultcompany"].contains(vendor),
            !Self.commonWords.contains(vendor)
        else { return [] }
        let squeezedVendor = vendor.replacingOccurrences(of: "-", with: "")

        // The app's names, and each without words that are the vendor's ("Google Chrome" → "Chrome").
        var products = Set<String>()
        for name in [application.name] + application.alternateNames {
            let words = name.split(separator: " ").map(String.init)
            let kept = words.filter { $0.lowercased().replacingOccurrences(of: "-", with: "") != squeezedVendor && !squeezedVendor.hasPrefix($0.lowercased()) }
            // Each also without a trailing version or year ("Adobe Photoshop 2026" → "Photoshop").
            let unversioned = [words, kept].compactMap { list -> [String]? in
                guard list.count > 1, let last = list.last, last.allSatisfy({ $0.isNumber || $0 == "." }) || last.count == 1 else { return nil }
                return Array(list.dropLast())
            }
            for candidate in [words, kept] + unversioned where !candidate.isEmpty {
                for joined in [candidate.joined(separator: " "), candidate.joined(separator: "-"), candidate.joined()] where joined.count >= 3 {
                    products.insert(joined.lowercased())
                }
            }
        }
        // A product another installed app is named after belongs to that app, not this one.
        let otherNames = Set(others.flatMap { [$0.name] + $0.alternateNames }.map { $0.lowercased() })
        products.subtract(otherNames)
        guard !products.isEmpty else { return [] }
        func isProduct(_ entry: String) -> Bool {
            let lowered = entry.lowercased()
            return products.contains { product in
                guard lowered.hasPrefix(product) else { return false }
                let rest = lowered.dropFirst(product.count).drop { $0 == " " || $0 == "-" || $0 == "_" }
                return rest.allSatisfy { $0.isNumber || $0 == "." } && (rest.first?.isNumber ?? true)
            }
        }

        var findings: [Finding] = []
        let user = roots.home.appending(path: "Library", directoryHint: .isDirectory)
        for library in [user, roots.library] {
            for base in ["Application Support", "Caches", "Logs", "Preferences"].map({ library.appending(path: $0, directoryHint: .isDirectory) }) {
                for vendorFolder in collector.list(base) {
                    let lowered = vendorFolder.lowercased().replacingOccurrences(of: "-", with: "")
                    guard lowered == squeezedVendor || (squeezedVendor.count >= 4 && lowered.hasPrefix(squeezedVendor)) else { continue }
                    let folder = base.appending(path: vendorFolder, directoryHint: .isDirectory)
                    for entry in collector.list(folder) where isProduct(entry) {
                        findings.append(Finding(path: folder.appending(path: entry).path, tier: .name, reason: "\(vendorFolder)'s folder for the app"))
                    }
                }
            }
        }
        return findings
    }

    /// Generic words that are no evidence on their own (from Mole's list of common launch-agent words).
    static let commonWords: Set<String> = [
        "music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts", "messages", "reminders", "clock", "weather",
        "stocks", "books", "news", "podcasts", "voice", "files", "store", "system", "helper", "agent", "daemon", "service", "update", "updater", "sync",
        "backup", "cloud",
        "manager", "monitor", "server", "client", "worker", "runner", "launcher", "driver", "plugin", "extension", "widget", "utility", "app", "application",
        "electron",
        "chrome", "chromium", "java", "python", "node", "setup", "installer", "uninstaller", "main", "default", "data", "cache", "caches", "logs", "temp", "tmp"
    ]
}
