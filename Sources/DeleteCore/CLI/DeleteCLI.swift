import Darwin
import Foundation

public enum DeleteCLI {
    public static let version = "0.1.0"

    public static let usage = """
    Usage:
      delete list [--all] [--json]       Installed apps with size and source
      delete <app> [--dry-run] [-y]      Delete an app and everything it left behind

    <app> is a name, a bundle identifier, or a path; a unique name prefix is enough.

    Options:
      --all                     Also list macOS components and helper bundles
      --json                    Machine-readable output (list, and the plan with --dry-run)
      --dry-run                 Show what would be deleted, delete nothing
      -y, --yes                 Don't ask before deleting
      --include-name-matches    Also delete items matched only by the app's name
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

    /// Shows the plan, and unless it's a dry run, asks and deletes.
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
        let finder = EvidenceFinder(roots: roots)
        func makePlan() throws(Refusal) -> RemovalPlan {
            let plan = try finder.plan(for: application, inventory: inventory, timing: timing)
            return sandbox.map { $0.translate(plan) } ?? plan
        }
        var plan: RemovalPlan
        do { plan = try makePlan() } catch {
            printError(error.message)
            return EXIT_FAILURE
        }
        timing?.mark("find leftovers")
        let isRoot = geteuid() == 0 && sandbox == nil
        let name = application.name.terminalInline

        if invocation.dryRun {
            if invocation.json {
                do { print(try PlanRenderer.json(plan)) } catch {
                    printError("Unable to encode the plan: \(error.localizedDescription)")
                    return EXIT_FAILURE
                }
                return EXIT_SUCCESS
            }
            print(PlanRenderer.text(plan, includeNameMatches: invocation.includeNameMatches, isRoot: isRoot, home: roots.home))
            let needsSudo = !plan.split(includeNameMatches: invocation.includeNameMatches, isRoot: isRoot).needingRoot.isEmpty
            let hint = plan.appNeedsRoot(isRoot: isRoot) ? " Deleting it needs: sudo delete \(shellQuoted(application.path))" : needsSudo ? " Run with sudo to include the items that need administrator rights." : ""
            print("\nDry run: nothing was deleted." + hint)
            return EXIT_SUCCESS
        }
        guard !invocation.json else {
            printError("--json applies to \"delete list\" and --dry-run.")
            return 2
        }

        let actions: SystemActions = sandbox == nil ? LiveSystemActions(tools: roots.tools) : RecordingSystemActions()
        if let sandbox { print("Sandbox run: deleting the copies under \(sandbox.root); nothing outside it is touched.\n") }
        if application.source == .macPorts {
            printError("\(name) was installed by MacPorts. Remove it with \"sudo port uninstall <port>\" (\"port provides \(shellQuoted(application.path))/Contents/Info.plist\" names the port).")
            return EXIT_FAILURE
        }
        if !plan.activeSystemExtensions.isEmpty, sandbox == nil {
            print(PlanRenderer.text(plan, includeNameMatches: invocation.includeNameMatches, isRoot: isRoot, home: roots.home))
            printError("\nTurn off \(name)'s system extension first (in the app, or System Settings › General › Login Items & Extensions). Nothing was deleted.")
            return EXIT_FAILURE
        }

        // A running app is asked to quit first, then the plan is made again: apps write files
        // as they quit.
        if plan.running {
            guard invocation.assumeYes || ask("\(name) is running. Quit it? [y/N] ") else {
                print("Nothing was deleted.")
                return EXIT_FAILURE
            }
            if case let .stillRunning(names) = actions.quit(identifiers: plan.identifiers, bundlePath: application.bundlePath) {
                printError("\(names.joined(separator: ", ")) didn't quit. Nothing was deleted.")
                return EXIT_FAILURE
            }
            do { plan = try makePlan() } catch {
                printError(error.message)
                return EXIT_FAILURE
            }
            if sandbox != nil { plan.running = false }
        }

        print(PlanRenderer.text(plan, includeNameMatches: invocation.includeNameMatches, isRoot: isRoot, home: roots.home))
        let (selected, needingRoot) = plan.split(includeNameMatches: invocation.includeNameMatches, isRoot: isRoot)
        guard let question = PlanRenderer.question(plan, includeNameMatches: invocation.includeNameMatches, isRoot: isRoot) else {
            let reason = plan.appNeedsRoot(isRoot: isRoot) ? "\(name) itself needs administrator rights" : "Everything left needs administrator rights"
            printError("\n\(reason), so nothing was deleted. Run: sudo delete \(shellQuoted(application.path))")
            return EXIT_FAILURE
        }
        // What's deleted must be what was shown: identities are taken before asking.
        let targets = Executor.targets(for: selected, translate: sandbox?.translate ?? { $0 })
        print("")
        guard invocation.assumeYes || ask(question) else {
            print("Nothing was deleted.")
            return EXIT_FAILURE
        }
        let executor = Executor(actions: actions, allowedRoot: sandbox?.root ?? "/", home: roots.home, translate: sandbox.map { sandbox in { sandbox.translate($0) } } ?? { $0 })
        let report = executor.run(plan, targets: targets, isRoot: isRoot, casks: inventory.casks)
        print("")
        print(PlanRenderer.report(report, home: roots.home))
        if !needingRoot.isEmpty, report.stopped == nil {
            print("\n\(needingRoot.count) item\(needingRoot.count == 1 ? "" : "s") need administrator rights. Run: sudo delete \(shellQuoted(application.path))")
        }
        if let recording = actions as? RecordingSystemActions, !recording.recorded.isEmpty {
            print("\nSandbox: would also have run:")
            recording.recorded.forEach { print("  \($0)") }
        }
        return report.failed.isEmpty && report.stopped == nil ? EXIT_SUCCESS : EXIT_FAILURE
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

    /// A path as it can be pasted into a shell.
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    }

    var command: Command = .help
    var all = false
    var json = false
    var dryRun = false
    var assumeYes = false
    var includeNameMatches = false

    init(arguments: [String]) throws {
        var positional: [String] = []
        var optionsEnded = false
        for argument in arguments {
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
            case "--include-name-matches": includeNameMatches = true
            default: throw UsageError("Unknown option \(argument).")
            }
        }
        guard let first = positional.first else { command = .help; return }
        if first == "list" && !optionsEnded {
            guard positional.count == 1 else { throw UsageError("\"delete list\" takes no app name.") }
            guard !dryRun, !assumeYes, !includeNameMatches else { throw UsageError("--dry-run, -y and --include-name-matches apply to deleting an app.") }
            command = .list
            return
        }
        guard positional.count == 1 else { throw UsageError("Name one app at a time.") }
        guard !all else { throw UsageError("--all applies to \"delete list\".") }
        guard !(json && assumeYes) else { throw UsageError("--json applies to \"delete list\" and --dry-run.") }
        command = .remove(first)
    }
}

struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
