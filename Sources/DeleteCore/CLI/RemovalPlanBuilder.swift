import Foundation

/// The complete, de-duplicated removal plans for one requested app and its included companions.
struct RemovalPlanGroup {
    let plans: [RemovalPlan]
    let reasonsByApplicationPath: [String: String]
}

/// Resolves companions and builds their removal plans as one fail-closed group.
struct RemovalPlanBuilder {
    let inventory: Inventory
    let roots: Roots
    let includesCompanions: Bool
    let sandbox: Sandbox?
    let timing: Timing?

    func build(for application: InstalledApp) throws(Refusal) -> RemovalPlanGroup {
        // Apps installed with it go with it, unless they can't be deleted at all. --no-companions
        // can't split a cask's declared suite because the cask artifacts are modeled together.
        let companionResult = Protection.refusal(for: application) == nil
            ? Companions.find(for: application, inventory: inventory, roots: roots)
            : Companions.Result()
        let companions = companionResult.companions.filter {
            Protection.refusal(for: $0.application) == nil && (includesCompanions || $0.inseparable)
        }
        let reasons = Dictionary(uniqueKeysWithValues: companions.map { ($0.application.path, $0.reason) })
        let group = Set([application.path] + companions.map(\.application.path))
        timing?.mark("companions (\(companions.count))")

        let finder = EvidenceFinder(roots: roots)
        let companionPlans = companions.map { companion in
            Concurrent { () -> Result<RemovalPlan, Refusal> in
                var other = companion.application
                other.source = Inventory.source(of: other, casks: inventory.casks, receipts: inventory.receipts)
                do {
                    return .success(try finder.plan(for: other, inventory: inventory, group: group))
                } catch let error as Refusal {
                    return .failure(error)
                } catch {
                    return .failure(Refusal(message: error.localizedDescription))
                }
            }
        }

        var main = try finder.plan(for: application, inventory: inventory, group: group, timing: timing)
        if let folder = companionResult.folder, !companions.isEmpty { main.emptyFolders.append(folder) }
        if !companionResult.partOf.isEmpty {
            main.notes.append("It was installed as part of \(companionResult.partOf.map { $0.name.terminalInline }.joined(separator: " and ")); deleting \(companionResult.partOf.count == 1 ? "that" : "those") removes it too.")
        }
        if !companionResult.sameDeveloper.isEmpty {
            main.notes.append("Also by the same developer, not included: \(companionResult.sameDeveloper.map { $0.name.terminalInline }.joined(separator: ", ")).")
        }

        let results = companionPlans.map(\.value)
        if let failure = results.first(where: {
            if case .failure = $0 { return true }
            return false
        }), case let .failure(error) = failure {
            throw Refusal(message: "Couldn't safely plan the companion app: \(error.message)")
        }
        let plans = [main] + results.compactMap { result in
            if case let .success(plan) = result { return plan }
            return nil
        }
        // A companion whose every item another plan already deletes has nothing left to show.
        let distinct = RemovalPlan.deduplicated(plans).enumerated().compactMap { index, plan in
            index == 0 || !plan.findings.isEmpty || !plan.packages.isEmpty || !plan.launchItems.isEmpty ? plan : nil
        }
        let translated = sandbox.map { sandbox in distinct.map(sandbox.translate) } ?? distinct
        return RemovalPlanGroup(plans: translated, reasonsByApplicationPath: reasons)
    }
}
