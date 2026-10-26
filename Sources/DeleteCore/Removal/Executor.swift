import Darwin
import Foundation

public struct ExecutionReport: Sendable {
    public var deleted: [Finding] = []
    public var failed: [(finding: Finding, reason: String)] = []
    /// Removed by Homebrew before delete reached them.
    public var removedByHomebrew: [Finding] = []
    public var warnings: [String] = []
    /// Set when the run stopped before deleting anything (or after the app itself failed).
    public var stopped: String?

    public var freed: Int64 { (deleted + removedByHomebrew).reduce(0) { $0 + $1.size } }
}

/// Carries out a confirmed plan. Order matters: launch items are stopped first so nothing
/// relaunches; Homebrew uninstalls its cask; the app itself goes next, and if it can't be
/// deleted the run stops with the app's data intact; then the leftovers; then the records
/// (receipts, privacy permissions, Launch Services).
public struct Executor {
    public let actions: SystemActions
    /// Every target must lie inside this folder ("/" for a real run, the sandbox otherwise).
    public let allowedRoot: String
    public let home: URL

    public init(actions: SystemActions, allowedRoot: String, home: URL) {
        self.actions = actions
        self.allowedRoot = allowedRoot
        self.home = home
    }

    /// `targets` are the confirmed findings with the identities they had when confirmed.
    public func run(_ plan: RemovalPlan, targets: [(finding: Finding, target: RemovalTarget)], isRoot: Bool, casks: [InstalledCask]) -> ExecutionReport {
        var report = ExecutionReport()
        let targetPaths = Set(targets.map { $0.finding.path.lowercased() })

        // 1. Stop the launch items being deleted.
        for item in plan.launchItems where targetPaths.contains(item.plist.lowercased()) {
            if let error = actions.bootout(item) { report.warnings.append("Couldn't stop \(item.label): \(error)") }
        }

        // 2. Homebrew removes the app it installed (without --zap: its zap list is in the plan
        // and is deleted permanently below, where brew would move it to the Trash).
        var homebrewDone = false
        if let token = plan.homebrewCask, let cask = casks.first(where: { $0.token == token }) {
            if let error = actions.uninstallCask(token: token, prefix: cask.prefix) {
                report.stopped = "Homebrew couldn't uninstall \(token); nothing was deleted.\n\(error)"
                return report
            }
            homebrewDone = true
        }

        // 3. The app itself first, then everything else.
        let own = Set([plan.application.path, plan.application.bundlePath].map { $0.lowercased() })
        let isOwn: (Finding) -> Bool = { own.contains($0.path.lowercased()) || $0.reason == "Steam game folder" }
        let ordered = targets.filter { isOwn($0.finding) } + targets.filter { !isOwn($0.finding) }
        for item in ordered {
            switch Remover.remove(item.target, allowedRoot: allowedRoot, home: home) {
            case .success:
                report.deleted.append(item.finding)
            case .failure(.missing) where homebrewDone:
                report.removedByHomebrew.append(item.finding)
            case .failure(.missing):
                report.warnings.append("\(Format.path(item.finding.path, home: home)) was already gone.")
            case let .failure(error):
                report.failed.append((item.finding, error.message))
                if isOwn(item.finding) {
                    // Without the app gone, deleting its data would only break it.
                    report.stopped = "\(plan.application.name) itself couldn't be deleted, so its other files were left alone."
                    return report
                }
            }
        }

        // 4. Records: installer receipts (root only), privacy permissions, Launch Services.
        if !plan.packages.isEmpty {
            if isRoot {
                for package in plan.packages { if let error = actions.forgetPackage(package) { report.warnings.append("Couldn't forget receipt \(package): \(error)") } }
            } else {
                report.warnings.append("The installer receipt\(plan.packages.count == 1 ? "" : "s") \(plan.packages.joined(separator: ", ")) need\(plan.packages.count == 1 ? "s" : "") sudo to forget.")
            }
        }
        for identifier in plan.identifiers { _ = actions.resetPrivacy(identifier) }
        _ = actions.unregister(plan.application.path)
        return report
    }

    /// Records each finding's identity now, just before asking, so that anything that changes
    /// between the question and the deletion is left alone. `translate` maps a path into the
    /// sandbox (identity for real runs); the finding keeps its real path for everything but the
    /// removal itself. Findings that don't exist are dropped.
    public static func targets(for findings: [Finding], translate: (String) -> String = { $0 }) -> [(finding: Finding, target: RemovalTarget)] {
        findings.compactMap { finding in
            let path = translate(finding.path)
            guard let identity = FileIdentity.of(path) else { return nil }
            return (finding, RemovalTarget(path: path, identity: identity))
        }
    }
}

/// A sandbox run deletes a clone of the app's files instead of the real ones: the plan is made
/// from the real system (read-only), and every path is mapped into the sandbox folder, where
/// `Scripts/sandbox` cloned them. System actions are only recorded.
public struct Sandbox: Sendable {
    public let root: String

    public init?(path: String) {
        guard path.hasPrefix("/"), let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        root = String(cString: real)
        // Refuse a sandbox that is a system folder or the home folder itself.
        guard root.split(separator: "/").count >= 3 else { return nil }
    }

    public func translate(_ path: String) -> String { root + path }

    /// The plan with every path mapped into the sandbox and permissions judged there (clones
    /// belong to the user even when the originals belong to root).
    public func translate(_ plan: RemovalPlan) -> RemovalPlan {
        var plan = plan
        plan.findings = plan.findings.map { finding in
            var finding = finding
            let path = translate(finding.path)
            let parent = (path as NSString).deletingLastPathComponent
            var info = stat()
            finding.needsRoot = lstat(path, &info) == 0 && (info.st_uid != getuid() || access(parent, W_OK) != 0)
            return finding
        }
        return plan
    }
}
