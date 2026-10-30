import Foundation

/// The identity-bound targets captured after planning and before the final confirmation.
struct PreparedRemoval {
    let findingTargets: [[(finding: Finding, target: RemovalTarget)]]
    let launchTargets: [[String: Executor.LaunchTarget]]
    let receiptTargets: [[String: Executor.ReceiptTargets]]
    let emptyFolderTargets: [[String: RemovalTarget]]
    let fingerprint: String

    static func prepare(
        plans: [RemovalPlan],
        receipts: PackageReceipts,
        isRoot: Bool,
        sandbox: Sandbox?,
        home: URL
    ) throws(PreparationError) -> PreparedRemoval {
        let asRoot =
            isRoot
            || (sandbox == nil
                && plans.contains {
                    $0.needsRoot() || $0.emptyFolders.contains(where: Remover.needsRoot)
                })
        let translate: (String) -> String = sandbox.map { sandbox in { sandbox.translate($0) } } ?? { $0 }
        let selected = plans.map { $0.split(isRoot: asRoot).deleting }
        let unavailable = selected.flatMap { Executor.unavailableTargets(for: $0, translate: translate) }
        if !unavailable.isEmpty, sandbox == nil { throw .findings(unavailable) }
        let findingTargets = selected.map { Executor.targets(for: $0, translate: translate) }

        let launchCaptures = plans.map { Executor.launchTargets(for: $0.launchItems, translate: translate) }
        let missingLaunchItems = launchCaptures.flatMap(\.unavailable)
        if !missingLaunchItems.isEmpty, sandbox == nil { throw .launchItems(missingLaunchItems) }
        let launchTargets = launchCaptures.map(\.targets)

        let receiptCaptures = plans.map { Executor.receiptTargets(for: $0.packages, receipts: receipts) }
        let missingReceipts = receiptCaptures.flatMap(\.unavailable)
        if !missingReceipts.isEmpty, sandbox == nil { throw .receipts(missingReceipts) }
        let receiptTargets = receiptCaptures.map(\.targets)

        let emptyFolderTargets: [[String: RemovalTarget]] = plans.map { plan in
            plan.emptyFolders.reduce(into: [String: RemovalTarget]()) { targets, folder in
                let path = translate(folder)
                guard let identity = FileIdentity.of(path) else { return }
                // A cask's declarative artifacts can repeat a folder. It remains one target,
                // rather than turning malformed or redundant metadata into a process crash.
                targets[folder] = targets[folder] ?? RemovalTarget(path: path, identity: identity)
            }
        }
        let missingEmpty = zip(plans, emptyFolderTargets).flatMap { plan, targets in
            plan.emptyFolders.filter { targets[$0] == nil }
        }
        if !missingEmpty.isEmpty, sandbox == nil { throw .emptyFolders(missingEmpty) }

        var identities: [String: FileIdentity] = [:]
        for targets in findingTargets {
            for item in targets { identities["delete:\(item.finding.path)"] = item.target.identity }
        }
        for records in receiptTargets {
            for (package, targets) in records {
                identities["receipt:\(package):plist"] = targets.plist.identity
                identities["receipt:\(package):bom"] = targets.bom.identity
            }
        }
        for records in launchTargets {
            for (key, target) in records { identities["launchctl:\(key)"] = target.target.identity }
        }
        for targets in emptyFolderTargets {
            for (path, target) in targets { identities["rmdir:\(path)"] = target.identity }
        }
        return PreparedRemoval(
            findingTargets: findingTargets,
            launchTargets: launchTargets,
            receiptTargets: receiptTargets,
            emptyFolderTargets: emptyFolderTargets,
            fingerprint: RemovalPlan.fingerprint(plans, identities: identities)
        )
    }
}

/// A live filesystem object changed or disappeared while its deletion was being prepared.
enum PreparationError: Error {
    case findings([Finding])
    case launchItems([LaunchItem])
    case receipts([String])
    case emptyFolders([String])

    func message(home: URL) -> String {
        switch self {
        case let .findings(findings):
            "The filesystem changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n"
                + findings.map { "  \(Format.path($0.path, home: home))" }.joined(separator: "\n")
        case let .launchItems(items):
            "A launch item changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n"
                + items.map(\.plist).sorted().map { "  \(Format.path($0, home: home))" }.joined(separator: "\n")
        case let .receipts(receipts):
            "The installer receipt records changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n"
                + receipts.sorted().map { "  \($0)" }.joined(separator: "\n")
        case let .emptyFolders(folders):
            "The filesystem changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n"
                + folders.map { "  \(Format.path($0, home: home))" }.joined(separator: "\n")
        }
    }
}
