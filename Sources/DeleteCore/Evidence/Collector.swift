import Darwin
import Foundation

/// Gathers findings: lists each folder once, keeps the strongest finding per path, and applies
/// the rules every finding must pass.
struct Collector {
    let roots: Roots
    private var listings: [String: [String]] = [:]
    private(set) var findings: [Finding] = []
    private var exempt = Set<String>()
    private var checkedForOtherApps = Set<String>()
    private(set) var skipped: [Skipped] = []
    var unreadable: [String] = []

    init(roots: Roots) { self.roots = roots }

    /// The names in a folder, read once. A folder that exists but can't be read is recorded:
    /// without Full Disk Access, macOS hides other apps' data, and "nothing found" would be wrong.
    mutating func list(_ folder: URL) -> [String] {
        if let cached = listings[folder.path] { return cached }
        var names: [String] = []
        switch Directory.names(atPath: folder.path) {
        case let .success(found):
            names = found
        case let .failure(error):
            // Missing or not a folder means nothing there; anything else means "couldn't look".
            if error.code != ENOENT && error.code != ENOTDIR { unreadable.append(folder.path) }
        }
        listings[folder.path] = names
        return names
    }

    /// `exempt` findings (the app itself, a Steam game's folder) were chosen by the user or
    /// verified separately, so the protected-folder rules don't apply to them.
    mutating func add(_ finding: Finding, exempt isExempt: Bool = false, keepOtherAppsCheck: Bool = false) {
        let path = URL(filePath: finding.path).standardizedFileURL.path
        var finding = finding
        finding.path = path
        if isExempt { exempt.insert(path.lowercased()) }
        if keepOtherAppsCheck { checkedForOtherApps.insert(path.lowercased()) }
        if let index = findings.firstIndex(where: { $0.path.lowercased() == path.lowercased() }) {
            if findings[index].tier == .name, finding.tier == .exact { findings[index] = finding }
            return
        }
        findings.append(finding)
    }

    mutating func skip(_ path: String, _ reason: String) {
        guard !skipped.contains(where: { $0.path == path }) else { return }
        skipped.append(Skipped(path: path, reason: reason))
    }

    /// Drops anything protected, inside or containing another installed app, reached through a
    /// symbolic link, or already inside another finding.
    mutating func finish(otherApplicationPaths: Set<String>) -> [Finding] {
        let lowerOthers = otherApplicationPaths.map { $0.lowercased() }
        var kept: [Finding] = []
        for finding in findings {
            let lowered = finding.path.lowercased()
            let isExempt = exempt.contains(lowered)
            if !isExempt, Protection.isProtected(finding.path, roots: roots) {
                // Said for name matches too: deleting Steam keeps Steam's folder and its games.
                skip(finding.path, Protection.protectedReason(finding.path, roots: roots))
                continue
            }
            if !isExempt || checkedForOtherApps.contains(lowered), lowerOthers.contains(where: { $0 == lowered || $0.hasPrefix(lowered + "/") || lowered.hasPrefix($0 + "/") }) {
                skip(finding.path, "belongs to another installed app")
                continue
            }
            // The folder holding the item must be where its path says, not somewhere a link leads.
            let parent = URL(filePath: finding.path).deletingLastPathComponent()
            if parent.resolvingSymlinksInPath().path != parent.path, !Self.isSystemLink(parent.path) {
                skip(finding.path, "reached through a symbolic link")
                continue
            }
            kept.append(finding)
        }
        // An item inside another selected item is covered by it.
        let sorted = kept.sorted { $0.path.count < $1.path.count }
        var result: [Finding] = []
        for finding in sorted {
            let lowered = finding.path.lowercased()
            if let parent = result.first(where: { lowered.hasPrefix($0.path.lowercased() + "/") }), parent.tier == .exact || finding.tier == .name { continue }
            result.append(finding)
        }
        return result.sorted { ($0.tier == .exact ? 0 : 1, $0.path) < ($1.tier == .exact ? 0 : 1, $1.path) }
    }

    /// macOS's own links (/var → /private/var, /tmp → /private/tmp) don't count.
    private static func isSystemLink(_ path: String) -> Bool {
        ["/var", "/tmp", "/etc"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
