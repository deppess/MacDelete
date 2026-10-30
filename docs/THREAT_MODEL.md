# Threat model

`delete` permanently removes installed macOS applications and associated artifacts. This document
defines the security properties that take precedence over removal coverage or convenience.

## Security objective

Deletion is allowed only for the concrete objects the user reviewed. When ownership, readability,
identity, privilege, or completion cannot be established, `delete` leaves the object alone and
reports why.

## Assets to protect

- User documents, credentials, and unrelated application data.
- macOS system files and the sealed system volume.
- Files belonging to another installed application or another user.
- Root privileges and the user approval that authorizes their use.
- The accuracy of the displayed removal plan and exit status.

## Trust boundaries and adversaries

The following inputs are treated as untrusted or stale data, even when they originate locally:

| Boundary | Examples | Required behavior |
| --- | --- | --- |
| Filesystem namespace | symlinks, hard links, renames, mount points, permissions changing after confirmation | Capture and recheck identity; do not follow links; reject changed paths; do not cross volumes. |
| Application metadata | bundle plists, entitlements, embedded helpers, display names | Bound reads to small regular files; reject malformed or unsupported metadata; never widen a rule from malformed data. |
| Package and cask metadata | BOMs, receipts, Homebrew uninstall artifacts, launch labels | Model only exact, independently verifiable declarative artifacts; reject broad patterns, scripts, generated actions, unresolved services, and unknown directives. |
| Other installed apps | shared identifiers, app groups, packages, plug-ins, logs | Treat ambiguous ownership as shared and keep the item. |
| Process and system state | running applications, launchd jobs, TCC, Launch Services, package database | Stop launch items before deletion; stop on failure; report record-action failures and return nonzero. |
| Privilege transition | sudo re-execution and inherited command-line arguments | Bind approval to a canonical fingerprint of the plan and captured identities; rerender and ask again if it changes. |
| Terminal output | app names and metadata containing control characters | Sanitize output before it reaches the terminal. |

## Required invariants

1. **Plan before mutation.** Every file and system action is rendered before confirmation.
2. **Identity-bound mutation.** Before a target is removed, its device, inode, type, owner, group,
   and mode must still match the object captured after planning.
3. **Single deletion sink.** `Remover` is the only component that permanently removes filesystem
   objects. It independently enforces allowed-root, protected-path, symlink, and cross-volume
   checks.
4. **Fail closed.** Missing, unreadable, malformed, duplicate, changed, shared, protected, or
   unsupported evidence must not cause a deletion.
5. **Privilege does not widen scope.** A sudo rerun may proceed without a second question only
   when its versioned SHA-256 approval fingerprint is identical to the approved plan and captured
   targets.
6. **Launch barrier.** A launch item that cannot be stopped prevents every deletion in its group.
7. **No shell interpretation.** External tools use fixed executable paths and `posix_spawn` argv;
   application-derived strings are never interpreted by a shell.
8. **Sandbox containment.** Test and sandbox removal runs map all selected paths into the sandbox
   and record, rather than perform, non-filesystem system actions.

## Explicit non-goals

- Recovering or deleting leftovers after an application bundle is already gone.
- A general cache, disk, or document cleaner.
- Guessing ownership from a vendor name, a broad glob, a launch label alone, or a path prefix.
- Modeling imperative package-manager actions or arbitrary uninstall scripts.
- Secure erasure or shredding; modern APFS/FileVault systems do not provide this through `srm`.

## Validation strategy

Changes affecting this model require focused hostile-input tests plus `Scripts/quality`. Changes at
the deletion or privilege boundary additionally require AddressSanitizer, ThreadSanitizer, and
`Scripts/sandbox-all`. Disposable `Scripts/testapps` cases exercise the real deletion path; no
automated workflow may run `delete` destructively against an installed user application.
