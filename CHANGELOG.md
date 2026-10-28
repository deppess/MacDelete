# Changelog

All notable changes to `delete` are documented here.

## 2.0.0 — 2026-10-28

### Safety

- Stops and verifies every launch item in an app-and-companion group before deleting any file.
- Binds launch plist identities into the confirmation and sudo approval, then checks them again
  immediately before `launchctl bootout`.
- Refuses the complete operation when an intended companion cannot be planned safely.

### Changed

- Every finding shown in the deletion plan is included in its one confirmation.
- Name-derived findings are visibly labeled as lower-confidence evidence, including warnings for
  same-named home folders that may contain user files.
- Removed the obsolete `--include-name-matches` option; normal usage remains `delete <app>`.

## 1.0.0 — 2026-10-27

Initial source release of `delete`: a native macOS command-line uninstaller with bounded
discovery, identity-checked deletion, automatic sudo revalidation, companion handling, and
safe local modeling of supported Homebrew cask artifacts.
