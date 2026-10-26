# delete

`delete` is a macOS command-line tool that removes an installed application together with everything it left on the system: its data, caches, preferences, containers, launch agents, installer-package files and receipts, privacy permissions, and Launch Services registration. It supports macOS 15 and later and has no dependencies, network access, or background process.

Deletion is permanent. Nothing goes to the Trash and there is no undo; the plan shown before the question is exactly what is removed.

## Usage

```sh
delete list                       # installed apps with size and source; --all, --json
delete <app> --dry-run            # what would be deleted and why
delete <app>                      # show the plan, ask once, delete
sudo delete <app>                 # when the app or some of its files belong to root
```

`<app>` is a name, a bundle identifier, or a path, matched case-insensitively. A unique name prefix is enough; anything ambiguous lists the candidates and stops.

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

Only fixed locations are read; the disk is never crawled. Items named by the app's bundle identifier (or one of its embedded helpers', extensions', or login items'), its entitlement app groups, its installer-package receipt, launch items that run it, and browser native-messaging hosts pointing into it are selected. Items matched only by the app's name are shown but never selected without `--include-name-matches`. Anything another installed app also claims is kept and the reason shown. `CLAUDE.md` lists every rule and `PLAN.md` the research behind them.

What is refused: apps that are part of macOS, security and device-management agents (use the vendor's uninstaller), and MacPorts apps (use `port uninstall`). Running apps are asked to quit first. Homebrew casks are uninstalled through `brew uninstall --cask`, and their zap lists are deleted by `delete` itself. Without Full Disk Access some folders can't be read; the plan then says so instead of reporting nothing.

## Build and test

```sh
swift build
swift test                                 # fake system folders only; never touches the host
Scripts/install                            # release build to ~/.local/bin/delete
Scripts/sandbox clone "FL Studio 2026"     # APFS clones of everything the app's plan names
Scripts/sandbox run "FL Studio 2026" -y    # really deletes the clones; system actions are only recorded
```

GPL-3.0-or-later. See `NOTICE` for code taken from Sift and Mole.
