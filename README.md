# delete

`delete` is a macOS command-line tool that removes an installed application together with everything it left on the system: its data, caches, preferences, containers, launch agents, installer-package files and receipts, privacy permissions, and Launch Services registration. It supports macOS 15 and later and has no dependencies, network access, or background process.

It is built from source for the Mac on which it is installed: Apple-silicon installs are native `arm64`, not Rosetta-translated. This matters for macOS 28, where Apple says general Rosetta support ends. `Scripts/install` refuses to install an Intel-only build when launched from a Rosetta shell; open a native terminal instead. A native Intel Mac can continue to build the tool on macOS versions that support that hardware.

Deletion is permanent. Nothing goes to the Trash and there is no undo; the plan shown before the question lists every file deletion and system action. Each target is identity-checked immediately before mutation. A changed, ambiguous, protected, or unreadable target is left alone.

## Usage

```sh
delete list                       # installed apps with size and source; --all, --json
delete <app> --dry-run            # what would be deleted and why
delete <app>                      # show the plan, ask once, delete
delete <app> --no-companions      # leave the apps installed with it
```

When something in the plan belongs to root, `delete` still asks once, then reruns itself with `sudo`, which asks for your password. The rerun proceeds without asking again only if it finds the same plan and the same filesystem identities, ownership, and modes; otherwise it shows the new plan and asks. A launch item that cannot be stopped blocks deletion. Failed privacy, receipt, or Launch Services actions are reported and return a nonzero status.

Apps installed together with the app go with it, shown under their own heading with the reason. They're found from how apps were installed, never from a list of products: apps declared by the same Homebrew cask, apps from the same installer package, and apps in the app's own folder (`/Applications/DaVinci Resolve/`), each signed by the same developer; plus an app whose installer the app's package put on disk, and an uninstaller named after the app. In a group only its main app (the one the folder or package is named after, or one at least twice the size of the rest) takes the others, so deleting a utility never takes the app, and a suite of equal peers is never grouped. Other apps by the same developer are only mentioned.

Press Tab after `delete` to complete app names (with version, source and size), bundle identifiers, paths and options. `Scripts/install` sets this up for fish; for zsh, save `delete completions zsh` as `_delete` in a folder on `$fpath`, and for bash add `eval "$(delete completions bash)"` to your profile.

`<app>` is a name, a bundle identifier, or a path, matched case-insensitively. A unique name prefix is enough, except with `-y`, which needs the full name, identifier or path; anything ambiguous lists the candidates and stops.

```
FL Studio 2026   26.1.5.5384   2.7 GB   (Installer package)

  /Applications/FL Studio 2026.app                                        2.5 GB
  /Library/Audio/Plug-Ins/Components/FL Studio.component                   68 MB   installed by package com.Image-Line.pkg.26ONLINE
  ~/Library/Caches/com.image-line.flstudio                                 12 MB
  ~/Library/Preferences/com.image-line.flstudio.plist                       4 KB
  …

  Also: forgets the installer receipts com.Image-Line.pkg.flcloud.plugins, com.Image-Line.pkg.26ONLINE; resets its privacy permissions.

Permanently delete 9 items (2.7 GB)? [y/N]
```

## How files are found

Only fixed locations are read; the disk is never crawled. Items named by the app's bundle identifier (or one of its embedded helpers', extensions', or login items'), its entitlement app groups, its installer-package receipt, launch items that run it, browser native-messaging hosts and command-line links pointing into it, and plug-ins it installed into the Library (QuickLook, screen savers, audio plug-ins, …) are selected. A helper several apps of a suite embed (Office's error reporter) stays until the last of them goes. Same-named app artifacts (in Application Support, Caches, Logs, a same-named folder in the home directory, `~/.config`, `~/.local/share`, a regular executable in `~/.local/bin` or `~/bin`, `/Users/Shared`, a vendor's folder such as `JetBrains/IntelliJIdea2026.2`, …) are visibly labeled as name-derived evidence and included in the single confirmation. Some may hold your own files; review the complete plan before answering. Some things are only pointed out: iCloud and cloud-storage folders, a Dock tile, kernel extensions and audio drivers. Anything another installed app also claims is kept and the reason shown. `CLAUDE.md` lists every rule and `PLAN.md` the research behind them.

What is refused: apps that are part of macOS, security and device-management agents (use the vendor's uninstaller), and MacPorts apps (use `port uninstall`). Running apps are asked to quit first. For a Homebrew cask, `delete` reads the installed receipt and removes only the concrete artifacts it can reproduce under its own identity-checked deletion rules: app and suite bundles, Caskroom payloads, command links, `zap` paths, bounded declarative `uninstall delete`/`rmdir` entries, and `launchctl` labels only when they resolve to an on-disk LaunchAgent or LaunchDaemon plist that the plan shows and stops first. Declared `quit` identifiers must belong to the app or an embedded component; matching package-receipt identifiers are shown and forgotten through the normal sudo-gated receipt action. Root-owned paths remain in the plan and trigger the normal sudo revalidation. Casks with scripts, unresolved services, generated files, unsafe package patterns, or unknown directives are refused until `delete` has an equally bounded implementation. Without Full Disk Access some folders can't be read; the plan then says so instead of reporting nothing.

## Build and test

```sh
swift build
swift test                                 # fake system folders only; never touches the host
Scripts/install                            # native release build to ~/.local/bin/delete
Scripts/sandbox clone "FL Studio 2026"     # APFS clones of everything the app's plan names
Scripts/sandbox run "FL Studio 2026" -y    # really deletes the clones; system actions are only recorded
Scripts/sandbox-all                        # sandbox-deletes every installed app in turn and checks each result
Scripts/testapps plain | brew | package    # disposable test apps: plain download, Homebrew cask, installer package
Scripts/testapps suite | shared | all      # a two-app cask, two apps sharing an app group; all but package
Scripts/testapps check                     # after deleting them: anything left behind, and what must survive
Scripts/testapps clean                     # then: remove the disposable-app builds
```

GPL-3.0-or-later. See `NOTICE` for code taken from Sift and Mole.
