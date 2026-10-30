# Contributing to MacDelete

MacDelete permanently removes applications and their associated artifacts. Correctness and safety
are more important than coverage, convenience, or a smaller diff.

## Safety contract

Never run `delete` without `--dry-run` against an installed user application. To exercise real
removal behavior, use only the APFS-clone sandbox or the disposable test applications:

```sh
Scripts/sandbox clone "App Name"
Scripts/sandbox run "App Name" -y
Scripts/testapps validate
```

Do not weaken `.claude/hooks/guard-delete.py`. A destructive run must retain these guarantees:

- every filesystem and system action is rendered before confirmation;
- every selected filesystem object is identity-checked immediately before mutation;
- a sudo rerun proceeds without another question only when the plan and captured identities still
  match the approved fingerprint;
- an ambiguous, shared, protected, unreadable, changed, or unsupported artifact is left alone;
- a failed launch-item stop blocks deletion before any group member is removed.

The complete trust boundaries and invariants are in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Development checks

Run these before submitting a behavior or safety change:

```sh
Scripts/quality
Scripts/sandbox-all
Scripts/testapps validate
Scripts/benchmark 3
```

`Scripts/benchmark` is informational only. Its result depends on the local application inventory,
Spotlight, and filesystem state; it must not be used as a fixed CI threshold.

Apply the Swift formatting policy with:

```sh
Scripts/format
```

Formatting-only changes must be committed separately from functional changes.

## Change design

Keep each change focused: refactor, behavior, performance, test infrastructure, or documentation.
Do not mix categories. A new discovery or deletion rule needs tests for its normal, ambiguous, and
hostile inputs, its rendered plan, its failure behavior, and its sandbox behavior.

Before expanding Homebrew support, answer all of these questions in code and tests:

1. What exact local artifact is modeled?
2. How is its ownership independently proven?
3. How is it rendered and confirmed?
4. How is it bound to the sudo approval fingerprint when necessary?
5. What happens when it cannot be completed?

If any answer is unclear, refuse the directive rather than guessing.

## Architecture

- `Sources/DeleteCore/CLI`: commands, confirmation, and sudo rerun.
- `Sources/DeleteCore/Discovery`: installed-app, cask, and receipt inventory.
- `Sources/DeleteCore/Evidence`: bounded ownership evidence and removal-plan construction.
- `Sources/DeleteCore/Removal`: target identity checks, launch/system actions, and permanent
  removal.
- `Sources/DeleteCore/Output`: text, JSON, completion, and terminal-safe rendering.
- `Tests/DeleteCoreTests`: fake-root unit and integration tests that never mutate the host.

Read `HANDOFF.md` and `CLAUDE.md` before changing the removal model. They record the project’s
deliberate safety boundaries and validation history.
