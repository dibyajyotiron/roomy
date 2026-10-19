# Roomy

Make room on your Mac. A native SwiftUI app for macOS 26 that cleans with Mole (GPL-3.0); GPL-3.0 as a whole. Credits are in `../NOTICE.md`.

## Build

**Xcode:** open `../Roomy.xcworkspace` and run the Roomy scheme. MoleCore (`../Packages/MoleCore`) and Pow (`../Vendor/Pow`) are local Swift packages.
The project is generated from `project.yml`; after adding or moving files, run `xcodegen generate` in this folder.

**Command line:**

```bash
Roomy/build.sh --open
```

The script builds MoleCore and Pow as modules, then the app, bundle, icon and an ad-hoc signature, into `Roomy/build/Roomy.app`. A Homebrew Mole (`brew install mole`) is copied into the app as its built-in engine.
It uses Xcode's toolchain when Xcode is installed and falls back to the Command Line Tools.

## How it's put together

- `Sources/Engine/Mole.swift` runs the newest working Mole: the one inside the app, or a newer release that `MoleUpdater.swift` downloaded, checked against its SHA-256 sums and tested.
- `Sources/Engine` scans: Mole's dry-run and JSON modes (`mo clean/purge/installer/optimize --dry-run`, `analyze --json`, `status --json`, `uninstall --list`), the MoleCore Swift port for sizing and path safety, and native scanners for apps, AI tools, storage, duplicates and similar photos. Scanning never changes anything.
- `Sources/Engine/Actions.swift` is the only code that changes the disk. **Safe mode is on by default**: cleaning then only records what it would have removed. With Safe mode off, files go to the Trash after MoleCore's path checks, and tool-managed items use the tool's own command (`docker builder prune`, `git worktree remove`, `npm uninstall -g`).
- Never offered for removal: macOS, other accounts, anything an open app is using, Docker volumes and containers, worktrees with uncommitted changes, models, sandboxes, sign-ins and settings.
- `Sources/UI` is SwiftUI: NavigationSplitView with the collapsible sidebar, Swift Charts, Quick Look, SF Symbols, and Pow for a few effects. `LiquidIcon.swift` draws the module icons and `RoomScene.swift` the living room.
