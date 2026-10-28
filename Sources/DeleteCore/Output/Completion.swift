import Foundation

public enum CompletionShell: String, Sendable, CaseIterable {
    case fish, zsh, bash
}

/// Tab completion. The scripts call `delete __complete <word>`, which prints one candidate per
/// line as `value<TAB>description`: the apps delete would accept (the user's own, Steam games
/// folded with their shortcuts, removable Apple apps), never ones it refuses.
public enum Completion {
    public static func candidates(for word: String, applications: [InstalledApp]) -> [(value: String, description: String)] {
        let offered = Inventory.foldingSteamShortcuts(applications)
            .filter { $0.classification == .user && Protection.refusal(for: $0) == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let lowered = word.lowercased()
        // A word with a dot and no space reads as a bundle identifier.
        if lowered.contains("."), !lowered.contains(" ") {
            let byIdentifier = offered.compactMap { application in application.bundleIdentifier.map { ($0, application) } }
                .filter { $0.0.lowercased().hasPrefix(lowered) }
                .map { (value: clean($0.0), description: clean($0.1.name)) }
            if !byIdentifier.isEmpty { return byIdentifier }
        }
        var counts: [String: Int] = [:]
        for application in offered { counts[application.name.lowercased(), default: 0] += 1 }
        var seen = Set<String>()
        return offered.filter { lowered.isEmpty || $0.name.lowercased().hasPrefix(lowered) || $0.alternateNames.contains { $0.lowercased().hasPrefix(lowered) } }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .map { application in
                // Two apps with one name can only be told apart by path.
                let count = counts[application.name.lowercased()] ?? 1
                let details = count > 1 ? ["\(count) apps with this name: give a path"] : [application.version, application.source.label, application.size.map(Format.size)].compactMap { $0 }
                return (value: clean(application.name), description: clean(details.joined(separator: " · ")))
            }
    }

    public static func lines(_ candidates: [(value: String, description: String)]) -> String {
        candidates.map { "\($0.value)\t\($0.description)" }.joined(separator: "\n")
    }

    /// One line, no tabs: a candidate can't break the value/description format or the terminal.
    private static func clean(_ text: String) -> String {
        text.terminalInline.replacingOccurrences(of: "\t", with: " ")
    }

    public static func script(for shell: CompletionShell) -> String {
        switch shell {
        case .fish:
            #"""
            # delete: tab completion for fish. Installed by Scripts/install, or:
            #   delete completions fish > ~/.config/fish/completions/delete.fish

            # True until an app or subcommand has been typed (options don't count).
            function __delete_wants_target
                set -l tokens (commandline -opc)
                set -e tokens[1]
                for token in $tokens
                    switch $token
                        case '-*'
                        case '*'
                            return 1
                    end
                end
                return 0
            end

            function __delete_is_path
                string match -q -r -- '^[~/.]' (commandline -ct)
            end

            complete -c delete -f
            complete -c delete -n '__delete_wants_target; and not __delete_is_path' -a '(delete __complete (commandline -ct) 2>/dev/null)'
            complete -c delete -n '__delete_wants_target; and __delete_is_path' -a '(__fish_complete_path (commandline -ct))'
            complete -c delete -n '__delete_wants_target; and not __delete_is_path' -a list -d 'List installed apps'
            complete -c delete -n '__delete_wants_target; and not __delete_is_path' -a completions -d 'Print a shell completion script'
            complete -c delete -n '__fish_seen_subcommand_from completions' -a 'fish zsh bash'
            complete -c delete -n 'not __fish_seen_subcommand_from list completions' -s n -l dry-run -d 'Show what would be deleted, delete nothing'
            complete -c delete -n 'not __fish_seen_subcommand_from list completions' -s y -l yes -d "Don't ask before deleting"
            complete -c delete -n 'not __fish_seen_subcommand_from list completions' -l no-companions -d 'Leave the apps installed with it'
            complete -c delete -n 'not __fish_seen_subcommand_from completions' -l json -d 'Machine-readable output'
            complete -c delete -n '__fish_seen_subcommand_from list' -l all -d 'Also list macOS components and helpers'
            complete -c delete -s h -l help -d 'Show help'
            complete -c delete -l version -d 'Show the version'
            """#
        case .zsh:
            #"""
            #compdef delete
            # delete: tab completion for zsh. Put this in a folder on $fpath as _delete:
            #   delete completions zsh > ~/.zfunc/_delete   (with fpath+=~/.zfunc before compinit)

            _delete() {
                local -a options
                options=(
                    '(-n --dry-run)'{-n,--dry-run}'[Show what would be deleted, delete nothing]'
                    '(-y --yes)'{-y,--yes}"[Don't ask before deleting]"
                    '--no-companions[Leave the apps installed with it]'
                    '--json[Machine-readable output]'
                    '--all[Also list macOS components and helpers]'
                    '(- *)'{-h,--help}'[Show help]'
                    '(- *)--version[Show the version]'
                )
                _arguments -s $options '1:app:->target' '*::argument:->rest'
                case $state in
                    target)
                        if [[ $PREFIX == [~/.]* ]]; then
                            _files
                            return
                        fi
                        local -a candidates
                        local value description
                        while IFS=$'\t' read -r value description; do
                            candidates+=("${value//:/\\:}:$description")
                        done < <(delete __complete "$PREFIX" 2>/dev/null)
                        candidates+=('list:List installed apps' 'completions:Print a shell completion script')
                        _describe -t apps app candidates
                        ;;
                    rest)
                        [[ $words[1] == completions ]] && compadd fish zsh bash
                        ;;
                esac
            }

            _delete "$@"
            """#
        case .bash:
            #"""
            # delete: tab completion for bash. Load it from your profile:
            #   eval "$(delete completions bash)"

            _delete() {
                local current=${COMP_WORDS[COMP_CWORD]} i word
                COMPREPLY=()
                for ((i = 1; i < COMP_CWORD; i++)); do
                    word=${COMP_WORDS[i]}
                    [[ $word == completions ]] && { COMPREPLY=($(compgen -W 'fish zsh bash' -- "$current")); return; }
                    [[ $word != -* ]] && return
                done
                if [[ $current == -* ]]; then
                    COMPREPLY=($(compgen -W '--dry-run -n --yes -y --no-companions --json --all --help --version' -- "$current"))
                elif [[ $current == [~/.]* ]]; then
                    local IFS=$'\n'
                    COMPREPLY=($(compgen -f -- "$current"))
                else
                    local IFS=$'\n' value description
                    while IFS=$'\t' read -r value description; do
                        COMPREPLY+=("$(printf '%q' "$value")")
                    done < <(delete __complete "$current" 2>/dev/null)
                    COMPREPLY+=($(compgen -W 'list completions' -- "$current"))
                fi
            }
            complete -F _delete delete
            """#
        }
    }
}
