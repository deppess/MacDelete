import Darwin
import Foundation

public enum DeleteCLI {
    public static let version = "2.0.0"

    public static let usage = """
    Usage:
      delete list [--all] [--json]       Installed apps with size and source
      delete <app> [--dry-run] [-y]      Delete an app and everything it left behind
      delete completions <fish|zsh|bash> Print a tab-completion script for that shell

    <app> is a name, a bundle identifier, or a path; a unique name prefix is enough.

    Options:
      --all                     Also list macOS components and helper bundles
      --json                    Machine-readable output (list, and the plan with --dry-run)
      --dry-run                 Show what would be deleted, delete nothing
      -y, --yes                 Don't ask before deleting
      --no-companions           Leave the apps installed with it (FL Studio's FL Cloud Plugins)
      -h, --help                Show this help
      --version                 Show the version
    """

    public static func run(arguments: [String], roots: Roots = .live(), environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try Invocation(arguments: arguments)
        } catch {
            printError("\(error.localizedDescription)\nRun \"delete --help\" for usage.")
            return 2
        }
        let timing = environment["DELETE_TIMING"] == "1" ? Timing() : nil
        defer { if let timing { printError(timing.report) } }

        switch invocation.command {
        case .help:
            print(usage)
            return EXIT_SUCCESS
        case .version:
            print("delete \(version)")
            return EXIT_SUCCESS
        case let .completions(shell):
            print(Completion.script(for: shell))
            return EXIT_SUCCESS
        case let .complete(word):
            // Spotlight's sizes only: walking bundles Spotlight lacks would slow every Tab.
            let inventory = Inventory.load(roots: roots, sizes: false, timing: timing)
            let lines = Completion.lines(Completion.candidates(for: word, applications: inventory.applications))
            if !lines.isEmpty { print(lines) }
            return EXIT_SUCCESS
        case .list:
            let inventory = Inventory.load(roots: roots, timing: timing)
            let shown = Inventory.foldingSteamShortcuts(inventory.applications)
                .filter { invocation.all || $0.classification == .user }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            do {
                print(invocation.json ? try ListRenderer.json(shown, warnings: inventory.warnings) : ListRenderer.text(shown, home: roots.home))
            } catch {
                printError("Unable to encode the list: \(error.localizedDescription)")
                return EXIT_FAILURE
            }
            if !invocation.json { inventory.warnings.forEach { printError("warning: \($0.terminalInline)") } }
            timing?.mark("render")
            return inventory.complete ? EXIT_SUCCESS : EXIT_FAILURE
        case let .remove(query):
            // Launch Services is connected to while the apps are scanned.
            let launchServices = Concurrent { RunningApps.prepare() }
            defer { launchServices.value }
            let inventory = Inventory.load(roots: roots, sizes: false, timing: timing)
            // Only a plan that's shown and answered may come from a name prefix.
            let allowPrefix = invocation.dryRun || !invocation.assumeYes
            switch AppMatcher.match(query, in: inventory.applications, home: roots.home, allowPrefix: allowPrefix) {
            case let .prefixOnly(application):
                printError("\"\(query.terminalInline)\" only matches the start of \(application.name.terminalInline)'s name. With -y, give its full name, bundle identifier or path.")
                return EXIT_FAILURE
            case .notFound:
                printError("No app matches \"\(query.terminalInline)\". Run \"delete list\" to see installed apps.")
                return EXIT_FAILURE
            case let .ambiguous(candidates):
                printError("\"\(query.terminalInline)\" matches several apps:")
                for candidate in candidates { printError("  \(candidate.name.terminalInline)   \(Format.path(candidate.path, home: roots.home).terminalInline)") }
                printError("Give the full name, the bundle identifier, or the path.")
                return EXIT_FAILURE
            case var .found(application):
                application.source = Inventory.source(of: application, casks: inventory.casks, receipts: inventory.receipts)
                return remove(application, inventory: inventory, invocation: invocation, roots: roots, environment: environment, timing: timing)
            }
        }
    }

    /// Shows the plan (the app's and its companions'), and unless it's a dry run, asks and
    /// deletes. Without root, a plan that needs it is shown whole and, once confirmed, delete
    /// reruns itself under sudo, which asks for the password.
    static func remove(_ application: InstalledApp, inventory: Inventory, invocation: Invocation, roots: Roots, environment: [String: String], timing: Timing?) -> Int32 {
        // A sandbox run deletes clones under DELETE_SANDBOX instead of the real files.
        var sandbox: Sandbox?
        if let path = environment["DELETE_SANDBOX"]?.nonEmpty {
            guard let valid = Sandbox(path: path) else {
                printError("DELETE_SANDBOX must be an existing folder at least two levels deep: \(path.terminalInline)")
                return 2
            }
            sandbox = valid
        }
        let isRoot = geteuid() == 0 && sandbox == nil
        if invocation.approved != nil, !isRoot {
            printError("--approved is only for delete's own rerun under sudo.")
            return 2
        }

        // Apps installed with it go with it, unless they can't be deleted at all. --no-companions
        // can't split a cask's declared suite because the cask artifacts are modeled together.
        let found = Protection.refusal(for: application) == nil ? Companions.find(for: application, inventory: inventory, roots: roots) : Companions.Result()
        let companions = found.companions.filter { Protection.refusal(for: $0.application) == nil && (invocation.withCompanions || $0.inseparable) }
        var reasons: [String: String] = [:]
        for companion in companions { reasons[companion.application.path] = companion.reason }
        let group = Set([application.path] + companions.map(\.application.path))
        timing?.mark("companions (\(companions.count))")

        let finder = EvidenceFinder(roots: roots)
        func makePlans() throws(Refusal) -> [RemovalPlan] {
            // The companions' plans are made while the app's is.
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
            if let folder = found.folder, !companions.isEmpty { main.emptyFolders.append(folder) }
            if !found.partOf.isEmpty {
                main.notes.append("It was installed as part of \(found.partOf.map { $0.name.terminalInline }.joined(separator: " and ")); deleting \(found.partOf.count == 1 ? "that" : "those") removes it too.")
            }
            if !found.sameDeveloper.isEmpty {
                main.notes.append("Also by the same developer, not included: \(found.sameDeveloper.map { $0.name.terminalInline }.joined(separator: ", ")).")
            }
            let results = companionPlans.map { $0.value }
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
            // A companion whose every item another plan already deletes (a helper inside a folder
            // the app's package installed) has nothing left to show.
            let distinct = RemovalPlan.deduplicated(plans).enumerated().filter { $0.offset == 0 || !$0.element.findings.isEmpty || !$0.element.packages.isEmpty || !$0.element.launchItems.isEmpty }.map(\.element)
            return sandbox.map { sandbox in distinct.map(sandbox.translate) } ?? distinct
        }
        var plans: [RemovalPlan]
        do { plans = try makePlans() } catch {
            printError(error.message)
            return EXIT_FAILURE
        }
        timing?.mark("find leftovers")
        func elevates(_ plans: [RemovalPlan]) -> Bool {
            sandbox == nil && !isRoot && plans.contains {
                $0.needsRoot() || $0.emptyFolders.contains(where: Remover.needsRoot)
            }
        }
        func render(_ plans: [RemovalPlan], asRoot: Bool) -> String {
            PlanRenderer.text(plans, reasons: reasons, isRoot: asRoot, home: roots.home, width: terminalWidth)
        }

        if invocation.dryRun {
            if invocation.json {
                do { print(try PlanRenderer.json(plans[0], companions: plans.dropFirst().map { ($0, reasons[$0.application.path] ?? "") })) } catch {
                    printError("Unable to encode the plan: \(error.localizedDescription)")
                    return EXIT_FAILURE
                }
                return EXIT_SUCCESS
            }
            let elevate = elevates(plans)
            print(render(plans, asRoot: isRoot || elevate))
            let hint = elevate ? " Deleting it needs administrator rights; delete will ask for your password." : sandbox != nil && plans.contains { $0.needsRoot() } ? " Some of it needs administrator rights." : ""
            print("\nDry run: nothing was deleted." + hint)
            return EXIT_SUCCESS
        }
        // Ownership decisions depend on the complete application, Homebrew and receipt indexes.
        // A dry run may still show the best available evidence, but a destructive run must never
        // infer that another app or package is absent because one of those indexes could not load.
        if !inventory.complete, sandbox == nil {
            printError("Can't safely delete while discovery is incomplete. Nothing was deleted.\n" + inventory.warnings.map { "  \($0)" }.joined(separator: "\n"))
            return EXIT_FAILURE
        }
        let actions: SystemActions = sandbox == nil ? LiveSystemActions(tools: roots.tools) : RecordingSystemActions()
        if let sandbox { print("Sandbox run: deleting the copies under \(sandbox.root); nothing outside it is touched.\n") }
        if let blocked = plans.first(where: { !$0.activeSystemExtensions.isEmpty }), sandbox == nil {
            print(render(plans, asRoot: isRoot || elevates(plans)))
            printError("\nTurn off \(blocked.application.name.terminalInline)'s system extension first (in the app, or System Settings › General › Login Items & Extensions). Nothing was deleted.")
            return EXIT_FAILURE
        }

        // Running apps are asked to quit first, then the plans are made again: apps write files
        // as they quit.
        let running = plans.filter(\.running)
        if !running.isEmpty {
            let names = running.map { $0.application.name.terminalInline }
            let question: String
            if names.count == 1 {
                question = "\(names[0]) is running. Quit it? [y/N] "
            } else if let last = names.last {
                question = "\(names.dropLast().joined(separator: ", ")) and \(last) are running. Quit them? [y/N] "
            } else {
                preconditionFailure("A non-empty running plan must have a name.")
            }
            guard invocation.assumeYes || invocation.approved != nil || ask(question) else {
                print("Nothing was deleted.")
                return EXIT_FAILURE
            }
            for plan in running {
                if case let .stillRunning(names) = actions.quit(identifiers: plan.identifiers, bundlePath: plan.application.bundlePath) {
                    printError("\(names.joined(separator: ", ")) didn't quit; it may be waiting for you to save or confirm something. Nothing was deleted.")
                    return EXIT_FAILURE
                }
            }
            do { plans = try makePlans() } catch {
                printError(error.message)
                return EXIT_FAILURE
            }
            if sandbox != nil { for index in plans.indices { plans[index].running = false } }
        }

        let elevate = elevates(plans)
        let asRoot = isRoot || elevate
        // What's deleted must be what was shown: identities are taken before asking. A finding
        // that vanished here must not silently drop out of `targets`; make a fresh plan instead.
        let selected = plans.map { $0.split(isRoot: asRoot).deleting }
        let translator: (String) -> String
        if let sandbox { translator = { sandbox.translate($0) } } else { translator = { $0 } }
        let unavailable = selected.flatMap { Executor.unavailableTargets(for: $0, translate: translator) }
        guard unavailable.isEmpty || sandbox != nil else {
            printError("The filesystem changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n" + unavailable.map { "  \(Format.path($0.path, home: roots.home))" }.joined(separator: "\n"))
            return EXIT_FAILURE
        }
        let targets = selected.map { Executor.targets(for: $0, translate: translator) }
        let launchCaptures = plans.map { Executor.launchTargets(for: $0.launchItems, translate: translator) }
        let launchTargets = launchCaptures.map(\.targets)
        let missingLaunchItems = launchCaptures.flatMap(\.unavailable)
        guard missingLaunchItems.isEmpty || sandbox != nil else {
            printError("A launch item changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n" + missingLaunchItems.map(\.plist).sorted().map { "  \(Format.path($0, home: roots.home))" }.joined(separator: "\n"))
            return EXIT_FAILURE
        }
        let receiptCaptures = plans.map { Executor.receiptTargets(for: $0.packages, receipts: inventory.receipts) }
        let receiptTargets = receiptCaptures.map(\.targets)
        let missingReceipts = receiptCaptures.flatMap(\.unavailable)
        guard missingReceipts.isEmpty || sandbox != nil else {
            printError("The installer receipt records changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n" + missingReceipts.sorted().map { "  \($0)" }.joined(separator: "\n"))
            return EXIT_FAILURE
        }
        let emptyTargets: [[String: RemovalTarget]] = plans.map { plan in
            Dictionary(uniqueKeysWithValues: plan.emptyFolders.compactMap { folder in
                let path = translator(folder)
                return FileIdentity.of(path).map { (folder, RemovalTarget(path: path, identity: $0)) }
            })
        }
        let missingEmpty = zip(plans, emptyTargets).flatMap { plan, targets in plan.emptyFolders.filter { targets[$0] == nil } }
        guard missingEmpty.isEmpty || sandbox != nil else {
            printError("The filesystem changed while preparing the deletion; nothing was deleted. Run delete again to see a fresh plan.\n" + missingEmpty.map { "  \(Format.path($0, home: roots.home))" }.joined(separator: "\n"))
            return EXIT_FAILURE
        }
        var approvalIdentities: [String: FileIdentity] = [:]
        for items in targets { for item in items { approvalIdentities["delete:\(item.finding.path)"] = item.target.identity } }
        for records in receiptTargets {
            for (package, targets) in records {
                approvalIdentities["receipt:\(package):plist"] = targets.plist.identity
                approvalIdentities["receipt:\(package):bom"] = targets.bom.identity
            }
        }
        for records in launchTargets {
            for (key, target) in records {
                approvalIdentities["launchctl:\(key)"] = target.target.identity
            }
        }
        for items in emptyTargets { for (path, target) in items { approvalIdentities["rmdir:\(path)"] = target.identity } }
        let fingerprint = RemovalPlan.fingerprint(plans, identities: approvalIdentities)
        // Delete's rerun under sudo goes ahead without asking when it found what was confirmed.
        let confirmed = invocation.approved == fingerprint
        if let approved = invocation.approved, !confirmed, !approved.isEmpty {
            print("With administrator rights, more turned up; this is the whole plan now:\n")
        }
        if !confirmed { print(render(plans, asRoot: asRoot)) }
        guard let question = PlanRenderer.question(plans, isRoot: asRoot) else {
            if plans[0].appNeedsRoot(isRoot: asRoot) || plans.contains(where: { !$0.split(isRoot: asRoot).needingRoot.isEmpty }) {
                printError("\nEverything here needs administrator rights, which a sandbox run doesn't have, so nothing was deleted.")
            } else {
                printError("\nNothing is selected to delete.")
            }
            return EXIT_FAILURE
        }
        if !confirmed {
            if elevate { print("\nSome of this needs administrator rights: macOS will ask for your password.") }
            print("")
            guard invocation.assumeYes || ask(question) else {
                print("Nothing was deleted.")
                return EXIT_FAILURE
            }
        }
        if elevate { return rerunWithSudo(application, fingerprint: fingerprint, invocation: invocation) }

        let executor = Executor(actions: actions, allowedRoot: sandbox?.root ?? "/", home: roots.home, translate: sandbox.map { sandbox in { sandbox.translate($0) } } ?? { $0 })
        let report = executor.run(group: plans, targets: targets, emptyTargets: emptyTargets, launchTargets: launchTargets, receiptTargets: receiptTargets, isRoot: isRoot, casks: inventory.casks)
        print("")
        print(PlanRenderer.report(report, home: roots.home))
        let needingRoot = plans.flatMap { $0.split(isRoot: isRoot).needingRoot }
        if !needingRoot.isEmpty, report.stopped == nil {
            print("\n\(needingRoot.count) item\(needingRoot.count == 1 ? "" : "s") need administrator rights, which a sandbox run doesn't have.")
        }
        if let recording = actions as? RecordingSystemActions, !recording.recorded.isEmpty {
            print("\nSandbox: would also have run:")
            recording.recorded.forEach { print("  \($0)") }
        }
        return report.failed.isEmpty && report.actionFailures.isEmpty && report.stopped == nil ? EXIT_SUCCESS : EXIT_FAILURE
    }

    /// Replaces this process with `sudo delete --approved <fingerprint> <app path>`: sudo asks
    /// for the password on the terminal, and the rerun deletes what was confirmed (or shows the
    /// plan again and asks, if running as root found more). Returns only if that can't start.
    static func rerunWithSudo(_ application: InstalledApp, fingerprint: String, invocation: Invocation) -> Int32 {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            printError("Couldn't find delete's own path to rerun it with sudo. Run: sudo delete \(Format.shellQuoted(application.path))")
            return EXIT_FAILURE
        }
        var arguments = ["/usr/bin/sudo", "--", executable, "--approved", fingerprint]
        if !invocation.withCompanions { arguments.append("--no-companions") }
        arguments += ["--", application.path]
        fflush(stdout)
        var pointers = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/sudo", &pointers)
        let error = String(cString: strerror(errno))
        pointers.forEach { free($0) }
        printError("Couldn't run sudo (\(error)). Run: sudo delete \(Format.shellQuoted(application.path))")
        return EXIT_FAILURE
    }

    /// Standard output's width in columns when it's a terminal, nil otherwise.
    static var terminalWidth: Int? {
        guard isatty(STDOUT_FILENO) == 1 else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }

    /// Asks a yes/no question on the terminal. Only "y" or "yes" is yes; no terminal, an empty
    /// answer or a failed read is no.
    static func ask(_ question: String) -> Bool {
        guard let terminal = fopen("/dev/tty", "r+") else {
            printError("\(question.trimmingCharacters(in: .whitespaces))\nNo terminal to answer on; rerun in a terminal, or with -y.")
            return false
        }
        defer { fclose(terminal) }
        fputs(question, terminal)
        fflush(terminal)
        var buffer = [CChar](repeating: 0, count: 64)
        guard fgets(&buffer, Int32(buffer.count), terminal) != nil else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let answer = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    static func printError(_ message: String) {
        // Standard output is buffered and standard error isn't; flush so the two stay in order.
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct Invocation {
    enum Command: Equatable {
        case help, version, list
        case remove(String)
        case completions(CompletionShell)
        /// The hidden `__complete <word>` the completion scripts call.
        case complete(String)
    }

    var command: Command = .help
    var all = false
    var json = false
    var dryRun = false
    var assumeYes = false
    var withCompanions = true
    /// Set by delete's own rerun under sudo: the fingerprint of the plan that was confirmed.
    var approved: String?

    init(arguments: [String]) throws {
        // The word being completed may itself look like an option.
        if arguments.first == "__complete" {
            guard arguments.count <= 2 else { throw UsageError("__complete takes one word.") }
            command = .complete(arguments.count == 2 ? arguments[1] : "")
            return
        }
        var positional: [String] = []
        var optionsEnded = false
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                positional.append(argument)
                continue
            }
            switch argument {
            case "--": optionsEnded = true
            case "-h", "--help": command = .help; return
            case "--version": command = .version; return
            case "--all": all = true
            case "--json": json = true
            case "--dry-run", "-n": dryRun = true
            case "-y", "--yes": assumeYes = true
            case "--no-companions": withCompanions = false
            case "--approved":
                guard let value = remaining.popFirst(), !value.hasPrefix("-") else { throw UsageError("--approved takes a fingerprint.") }
                approved = value
            default: throw UsageError("Unknown option \(argument).")
            }
        }
        guard let first = positional.first else { command = .help; return }
        if first == "list" && !optionsEnded {
            guard positional.count == 1 else { throw UsageError("\"delete list\" takes no app name.") }
            guard !dryRun, !assumeYes, withCompanions, approved == nil else { throw UsageError("--dry-run, -y and --no-companions apply to deleting an app.") }
            command = .list
            return
        }
        if first == "completions" && !optionsEnded {
            guard positional.count == 2, let shell = CompletionShell(rawValue: positional[1]) else { throw UsageError("\"delete completions\" takes one of: fish, zsh, bash.") }
            command = .completions(shell)
            return
        }
        guard positional.count == 1 else { throw UsageError("Name one app at a time.") }
        guard !all else { throw UsageError("--all applies to \"delete list\".") }
        guard !json || dryRun else { throw UsageError("--json applies to \"delete list\" and --dry-run.") }
        guard approved == nil || !dryRun else { throw UsageError("--approved can't be combined with --dry-run.") }
        command = .remove(first)
    }
}

struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
