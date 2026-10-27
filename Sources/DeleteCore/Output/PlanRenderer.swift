import Foundation

public enum PlanRenderer {
    /// What will be deleted and why, in the order: items, items needing sudo, name-only matches,
    /// kept items, other actions, notes.
    /// `width` is the terminal's, when output goes to one: paths are aligned to the longest that
    /// still leaves room for the sizes. Otherwise (a file, a pipe) every path is aligned.
    public static func text(_ plan: RemovalPlan, includeNameMatches: Bool, isRoot: Bool, home: URL, width: Int? = nil) -> String {
        let (deleting, needingRoot) = plan.split(includeNameMatches: includeNameMatches, isRoot: isRoot)
        let nameOnly = includeNameMatches ? [] : plan.findings.filter { $0.tier == .name }

        // One set of column widths for every listed item, so sizes line up across sections.
        let listed = deleting + needingRoot + nameOnly
        let sizeWidth = listed.map { size($0).count }.max() ?? 0
        let longest = listed.map { display($0.path, home: home).terminalDisplayWidth }.max() ?? 0
        let pathWidth = width.map { min(longest, max(40, $0 - sizeWidth - 6)) } ?? longest
        func row(_ finding: Finding) -> String {
            let path = display(finding.path, home: home)
            let padding = String(repeating: " ", count: max(2, pathWidth - path.terminalDisplayWidth + 2))
            let sizeText = size(finding)
            let line = "  " + path + padding + String(repeating: " ", count: sizeWidth - sizeText.count) + sizeText
            return finding.reason.map { line + "   " + $0.terminalInline } ?? line
        }

        let application = plan.application
        let total = (deleting + needingRoot).reduce(Int64(0)) { $0 + $1.size }
        var header = [application.name.terminalInline, application.version?.terminalInline, Format.size(total), "(\(sourceLabel(application.source)))"].compactMap { $0 }.joined(separator: "   ")
        if plan.running { header += "   running" }
        var lines = [header]
        if !deleting.isEmpty { lines += [""] + ordered(deleting, plan: plan).map(row) }

        if plan.appNeedsRoot(isRoot: isRoot) {
            lines += ["", "  \(application.name.terminalInline) itself needs administrator rights, so all of this needs sudo:"] + ordered(needingRoot, plan: plan).map(row)
        } else if !needingRoot.isEmpty {
            lines += ["", "  Needs administrator rights (run with sudo to include these):"] + needingRoot.map(row)
        }
        if !nameOnly.isEmpty {
            lines += ["", "  Not included (matched by name only; add with --include-name-matches):"] + nameOnly.map(row)
        }
        if !plan.skipped.isEmpty {
            // Reasons aligned among themselves (kept items have no size column).
            let kept = plan.skipped.map { (display($0.path, home: home), $0.reason.terminalInline) }
            let keptWidth = width.map { min(kept.map { $0.0.terminalDisplayWidth }.max() ?? 0, max(40, $0 - 40)) } ?? (kept.map { $0.0.terminalDisplayWidth }.max() ?? 0)
            lines += ["", "  Kept:"] + kept.map { path, reason in "  " + path + String(repeating: " ", count: max(3, keptWidth - path.terminalDisplayWidth + 3)) + reason }
        }

        var also: [String] = []
        if let cask = plan.homebrewCask { also.append("Homebrew uninstalls the cask (brew uninstall --cask \(cask))") }
        if !plan.launchItems.isEmpty { also.append("stops \(count(plan.launchItems.count, "launch item")) first") }
        if plan.emptyFolders.count == 1 {
            also.append("removes \(display(plan.emptyFolders[0], home: home)) if nothing is left in it")
        } else if plan.emptyFolders.count > 1 {
            also.append("removes \(count(plan.emptyFolders.count, "folder")) once they're empty (\(plan.emptyFolders.map { display($0, home: home) }.min { $0.count < $1.count } ?? "")…)")
        }
        if !plan.packages.isEmpty { also.append("forgets the installer receipt\(plan.packages.count == 1 ? "" : "s") \(plan.packages.joined(separator: ", "))\(isRoot ? "" : " (needs sudo)")") }
        if !plan.identifiers.isEmpty { also.append("resets its privacy permissions") }
        if !also.isEmpty { lines += ["", "  Also: " + also.joined(separator: "; ") + "."] }

        var notes = plan.notes
        if plan.running { notes.insert("\(application.name.terminalInline) is running; it will be asked to quit first.", at: 0) }
        if !plan.unreadable.isEmpty {
            notes.append("Couldn't read \(count(plan.unreadable.count, "folder")) (\(plan.unreadable.prefix(3).map { display($0, home: home) }.joined(separator: ", "))\(plan.unreadable.count > 3 ? ", …" : "")). Grant Full Disk Access to your terminal (System Settings › Privacy & Security) to see everything.")
        }
        if !notes.isEmpty { lines += [""] + notes.map { "  Note: " + $0 } }
        return lines.joined(separator: "\n")
    }

    /// An app's plan, then its companions' (apps installed with it, deleted with it), each with
    /// why it goes too. `reasons` are by app path.
    public static func text(_ plans: [RemovalPlan], reasons: [String: String], includeNameMatches: Bool, isRoot: Bool, home: URL, width: Int? = nil) -> String {
        guard let main = plans.first else { return "" }
        var parts = [text(main, includeNameMatches: includeNameMatches, isRoot: isRoot, home: home, width: width)]
        if plans.count > 1 {
            let keepable = plans.dropFirst().contains { $0.removedWithCask == nil && $0.homebrewCask == nil }
            parts.append("Installed with \(main.application.name.terminalInline), so deleted with it\(keepable ? " (keep \(plans.count == 2 ? "it" : "them") with --no-companions)" : ""):")
            for plan in plans.dropFirst() {
                var lines = text(plan, includeNameMatches: includeNameMatches, isRoot: isRoot, home: home, width: width).components(separatedBy: "\n")
                if let reason = reasons[plan.application.path] { lines[0] += "   " + reason.terminalInline }
                parts.append(lines.joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// The confirmation question for an app and its companions, or nil when there's nothing to
    /// delete.
    public static func question(_ plans: [RemovalPlan], includeNameMatches: Bool, isRoot: Bool) -> String? {
        let deleting = plans.flatMap { $0.split(includeNameMatches: includeNameMatches, isRoot: isRoot).deleting }
        guard !deleting.isEmpty else { return nil }
        let total = deleting.reduce(Int64(0)) { $0 + $1.size }
        let apps = plans.filter { !$0.split(includeNameMatches: includeNameMatches, isRoot: isRoot).deleting.isEmpty }.count
        return "Permanently delete \(count(deleting.count, "item"))\(apps > 1 ? " of \(apps) apps" : "") (\(Format.size(total)))? [y/N] "
    }

    /// The plan for scripts (and `Scripts/sandbox`, which clones exactly these paths).
    /// Companions follow under "companions", each a plan of its own with the reason it goes too.
    public static func json(_ plan: RemovalPlan, companions: [(plan: RemovalPlan, reason: String)] = []) throws -> String {
        struct Item: Encodable { let path: String; let tier: String; let reason: String?; let size: Int64; let sizeComplete: Bool; let needsRoot: Bool }
        struct Kept: Encodable { let path: String; let reason: String }
        struct Job: Encodable { let label: String; let plist: String; let domain: String }
        struct Document: Encodable {
            let name: String; let path: String; let bundleIdentifier: String?; let version: String?; let source: String; let homebrewCask: String?
            let identifiers: [String]; let findings: [Item]; let kept: [Kept]; let launchItems: [Job]; let packages: [String]; let unreadable: [String]; let emptyFolders: [String]
            let activeSystemExtensions: [String]; let running: Bool; let notes: [String]; let companionReason: String?; let companions: [Document]?
        }
        func document(_ plan: RemovalPlan, reason: String?, companions: [Document]?) -> Document {
            let application = plan.application
            return Document(
                name: application.name, path: application.path, bundleIdentifier: application.bundleIdentifier, version: application.version, source: application.source.label,
                homebrewCask: plan.homebrewCask, identifiers: plan.identifiers,
                findings: plan.findings.map { Item(path: $0.path, tier: $0.tier.rawValue, reason: $0.reason, size: $0.size, sizeComplete: $0.sizeComplete, needsRoot: $0.needsRoot) },
                kept: plan.skipped.map { Kept(path: $0.path, reason: $0.reason) },
                launchItems: plan.launchItems.map { Job(label: $0.label, plist: $0.plist, domain: $0.domain.rawValue) },
                packages: plan.packages, unreadable: plan.unreadable, emptyFolders: plan.emptyFolders, activeSystemExtensions: plan.activeSystemExtensions, running: plan.running, notes: plan.notes,
                companionReason: reason, companions: companions)
        }
        let document = document(plan, reason: nil, companions: companions.map { document($0.plan, reason: $0.reason, companions: nil) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    /// What happened, after deleting.
    public static func report(_ report: ExecutionReport, home: URL) -> String {
        var lines: [String] = []
        let count = report.deleted.count + report.removedByHomebrew.count
        if count > 0 { lines.append("Deleted \(Self.count(count, "item")) (\(Format.size(report.freed))).") }
        if !report.failed.isEmpty {
            lines += ["", "Couldn't delete:"] + report.failed.map { "  \(display($0.finding.path, home: home))   \($0.reason)" }
        }
        if let stopped = report.stopped { lines += ["", stopped] }
        if !report.warnings.isEmpty { lines += [""] + report.warnings.map { "Note: " + $0.terminalInline } }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    static func sourceLabel(_ source: AppSource) -> String {
        if case let .homebrew(token, _) = source { return "Homebrew cask \(token)" }
        return source.label
    }

    /// The app's own bundle first, then everything else by path.
    private static func ordered(_ findings: [Finding], plan: RemovalPlan) -> [Finding] {
        findings.filter(plan.isOwn) + findings.filter { !plan.isOwn($0) }
    }

    private static func display(_ path: String, home: URL) -> String { Format.path(path, home: home).terminalInline }
    private static func size(_ finding: Finding) -> String { finding.isLink ? "link" : Format.size(finding.size) + (finding.sizeComplete ? "" : "+") }
    private static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
}
