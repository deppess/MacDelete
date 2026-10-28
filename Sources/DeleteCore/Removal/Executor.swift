import Darwin
import Foundation

public struct ExecutionReport: Sendable {
    public var deleted: [Finding] = []
    public var failed: [(finding: Finding, reason: String)] = []
    /// Non-file system actions that did not complete. These make the command fail even when file
    /// removal succeeded, so the result never claims a complete uninstall.
    public var actionFailures: [String] = []
    public var warnings: [String] = []
    /// Set when the run stopped before deleting anything (or after the app itself failed).
    public var stopped: String?

    public var freed: Int64 { deleted.reduce(0) { $0 + $1.size } }
}

/// Carries out a confirmed plan. Order matters: launch items are stopped first so nothing
/// relaunches; privacy permissions are reset while the app is still registered; the app itself
/// goes next, and if it can't be deleted the run stops with the app's data intact; then the
/// leftovers; then the records (receipts, Launch Services).
public struct Executor {
    /// The receipt plist and BOM identities confirmed before `pkgutil --forget`. A receipt
    /// identifier is not reliably its file stem, so both concrete paths come from the local index.
    public struct ReceiptTargets: Sendable, Equatable {
        public var plist: RemovalTarget
        public var bom: RemovalTarget
    }
    public let actions: SystemActions
    /// Every target must lie inside this folder ("/" for a real run, the sandbox otherwise).
    public let allowedRoot: String
    public let home: URL

    /// Maps a planned path to the one acted on (into the sandbox for a sandbox run).
    public let translate: (String) -> String

    public init(actions: SystemActions, allowedRoot: String, home: URL, translate: @escaping (String) -> String = { $0 }) {
        self.actions = actions
        self.allowedRoot = allowedRoot
        self.home = home
        self.translate = translate
    }

    /// An app and its companions (`plans[0]` is the app). Companions go first, then the app.
    public func run(group plans: [RemovalPlan], targets: [[(finding: Finding, target: RemovalTarget)]], emptyTargets: [[String: RemovalTarget]] = [], receiptTargets: [[String: ReceiptTargets]] = [], isRoot: Bool, casks: [InstalledCask]) -> ExecutionReport {
        var report = ExecutionReport()
        let conditional = emptyTargets.count == plans.count ? emptyTargets : Array(repeating: [:], count: plans.count)
        let receipts = receiptTargets.count == plans.count ? receiptTargets : Array(repeating: [:], count: plans.count)
        for index in plans.indices.reversed() {
            let part = run(plans[index], targets: targets[index], emptyTargets: conditional[index], receiptTargets: receipts[index], isRoot: isRoot, casks: casks)
            report.deleted += part.deleted
            report.failed += part.failed
            report.actionFailures += part.actionFailures
            report.warnings += part.warnings
            if let stopped = part.stopped { report.stopped = [report.stopped, stopped].compactMap { $0 }.joined(separator: "\n") }
        }
        return report
    }

    /// Resets the app's privacy permissions, while it's still installed: tccutil finds the
    /// identifier through Launch Services and fails once the bundle is gone. Embedded helpers
    /// often aren't registered at all, so only the app's own failure is reported.
    public func resetPrivacy(_ plan: RemovalPlan) -> [String] {
        plan.identifiers.compactMap { identifier in
            guard let error = actions.resetPrivacy(identifier), identifier == plan.application.bundleIdentifier else { return nil }
            return "Couldn't reset \(plan.application.name.terminalInline)'s privacy permissions: \(error)"
        }
    }

    /// `targets` are the confirmed findings with the identities they had when confirmed.
    public func run(_ plan: RemovalPlan, targets: [(finding: Finding, target: RemovalTarget)], emptyTargets: [String: RemovalTarget] = [:], receiptTargets: [String: ReceiptTargets] = [:], isRoot: Bool, casks: [InstalledCask]) -> ExecutionReport {
        var report = ExecutionReport()
        let targetPaths = Set(targets.map { $0.finding.path.lowercased() })

        // 1. Stop the launch items being deleted.
        for item in plan.launchItems where targetPaths.contains(item.plist.lowercased()) {
            if let error = actions.bootout(item) {
                report.stopped = "Couldn't stop \(item.label): \(error). Nothing was deleted."
                return report
            }
        }

        // Stopping a launch item can't bring the app back, but one with KeepAlive may have
        // relaunched it since it was quit. Deleting a running app lets it write its files again.
        if !plan.launchItems.isEmpty, case let .stillRunning(names) = actions.quit(identifiers: plan.identifiers, bundlePath: plan.application.bundlePath) {
            report.stopped = "\(names.joined(separator: ", ")) started again and didn't quit; nothing was deleted."
            return report
        }

        report.actionFailures += resetPrivacy(plan)

        // 2. The app itself first, then everything else. Homebrew cask artifacts are removed
        // here too: all supported ones are concrete findings in the confirmed plan.
        let isOwn = plan.isOwn
        let ordered = targets.filter { isOwn($0.finding) } + targets.filter { !isOwn($0.finding) }
        for item in ordered {
            switch Remover.remove(item.target, allowedRoot: allowedRoot, home: home) {
            case .success:
                report.deleted.append(item.finding)
            case .failure(.missing):
                report.warnings.append("\(Format.path(item.finding.path, home: home)) was already gone.")
            case let .failure(error):
                report.failed.append((item.finding, error.message))
                if isOwn(item.finding) {
                    // Without the app gone, deleting its data would only break it.
                    if case .incomplete = error {
                        report.stopped = "\(plan.application.name) was only partly deleted, so its other files were left alone. Rerun with sudo to finish."
                    } else {
                        report.stopped = "\(plan.application.name) itself couldn't be deleted, so its other files were left alone."
                    }
                    return report
                }
            }
        }

        // Folders the zap list removes only when empty, now that their contents are gone.
        for folder in plan.emptyFolders {
            guard let target = emptyTargets[folder] else {
                report.failed.append((Finding(path: folder, tier: .exact, reason: "empty folder"), "changed since it was checked; left alone"))
                continue
            }
            switch Remover.removeIfEmpty(target, allowedRoot: allowedRoot, home: home) {
            case .success(true): report.deleted.append(Finding(path: folder, tier: .exact, reason: "empty folder"))
            case .success(false): report.warnings.append("Left \(Format.path(folder, home: home)): it is not empty.")
            case let .failure(error): report.failed.append((Finding(path: folder, tier: .exact, reason: "empty folder"), error.message))
            }
        }

        // 3. Records: installer receipts (root only), Launch Services.
        if !plan.packages.isEmpty {
            if isRoot {
                for package in plan.packages {
                    guard let targets = receiptTargets[package] else {
                        report.actionFailures.append("Couldn't forget receipt \(package): its plist or BOM was unavailable when the plan was confirmed")
                        continue
                    }
                    guard FileIdentity.of(targets.plist.path) == targets.plist.identity, FileIdentity.of(targets.bom.path) == targets.bom.identity else {
                        report.actionFailures.append("Couldn't forget receipt \(package): its plist or BOM changed since confirmation")
                        continue
                    }
                    if let error = actions.forgetPackage(package) { report.actionFailures.append("Couldn't forget receipt \(package): \(error)") }
                }
            } else {
                report.warnings.append("The installer receipt\(plan.packages.count == 1 ? "" : "s") \(plan.packages.joined(separator: ", ")) need\(plan.packages.count == 1 ? "s" : "") sudo to forget.")
            }
        }
        if let error = actions.unregister(plan.application.path) {
            report.actionFailures.append("Couldn't unregister \(plan.application.name.terminalInline) from Launch Services: \(error)")
        }
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

    /// Selected findings which disappeared or became impossible to identify before the question.
    /// They must not be silently omitted: the displayed plan would then differ from the operation
    /// the user is being asked to approve.
    public static func unavailableTargets(for findings: [Finding], translate: (String) -> String = { $0 }) -> [Finding] {
        findings.filter { FileIdentity.of(translate($0.path)) == nil }
    }

    /// Captures the actual receipt records, rather than guessing a `PackageIdentifier.plist`
    /// name. Missing records block a real run before the user confirms it.
    public static func receiptTargets(for packages: [String], receipts: PackageReceipts) -> (targets: [String: ReceiptTargets], unavailable: [String]) {
        var targets: [String: ReceiptTargets] = [:]
        var unavailable: [String] = []
        for package in packages {
            guard let files = receipts.files(for: package), let plist = FileIdentity.of(files.plist), let bom = FileIdentity.of(files.bom) else {
                unavailable.append(package)
                continue
            }
            targets[package] = ReceiptTargets(plist: RemovalTarget(path: files.plist, identity: plist), bom: RemovalTarget(path: files.bom, identity: bom))
        }
        return (targets, unavailable)
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
