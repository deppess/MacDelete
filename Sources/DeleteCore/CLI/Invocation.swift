import Foundation

/// A validated command-line request before it performs any filesystem or terminal work.
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
            guard positional.count == 2, let shell = CompletionShell(rawValue: positional[1]) else {
                throw UsageError("\"delete completions\" takes one of: fish, zsh, bash.")
            }
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
