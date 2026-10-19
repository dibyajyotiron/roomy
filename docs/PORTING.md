# Porting Mole's engine to Swift

Roomy is GPL-3.0 (see `NOTICE.md`). Parts of Mole's logic are ported into `Packages/MoleCore`, a Swift
package the app links, so Roomy can size and check paths natively with the same rules Mole uses.
Source: [tw93/mole](https://github.com/tw93/mole) at `b9361703158c` (2026-10-16).

## Rules for every ported file

1. The header names the Mole file and function it ports, plus the upstream commit.
2. Behavior first, idiom second: same decisions, same edge cases, same units (decimal GB).
3. Each ported unit ships with unit tests built on fixtures, plus a **parity test** that compares it
   with the installed `mo` on real data whenever Mole is present (`MoleCoreChecks --parity`).
4. Nothing deletes in tests. Destructive paths are tested only against temp fixtures.

## Module map

| Phase | Mole source | Swift (`MoleCore`) |
|---|---|---|
| **1 ✅** | `cmd/analyze/scanner.go` `countableFileSize`, `getActualFileSize`, `shouldFoldDirWithPath`, `du -skPx` sizing; `clone_darwin.go` `cloneIdentity`; `constants.go` `defaultSkipDirs`, `foldDirs` | `DiskUsage.swift`: `CloneIdentity`, `FileSizer`, `DirectorySizer` |
| **1 ✅** | `cmd/analyze/delete.go` `validatePath`, `isProtectedAnalyzeDeletePath`, `isCriticalAnalyzeDeletePath`, `isEndpointSecurityCachePath` | `PathSafety.swift` |
| **1 ✅** | `cmd/analyze/cleanable.go` | `Cleanable.swift` |
| **1 ✅** | `lib/core/base.sh` `bytes_to_human` | `ByteFormat.swift` |
| 2 | `lib/core/app_protection.sh` `should_protect_path`, `should_protect_data`, `is_critical_system_component`; `app_protection_data.sh` | `Protection.swift` + bundled data tables |
| 2 | `lib/core/whitelist.sh`, `lib/manage/whitelist.sh` | `Whitelist.swift` (reads `~/.config/mole/whitelist` format) |
| 3 | `bin/clean.sh` sections; `lib/clean/user.sh`, `caches.sh`, `app_caches.sh`, `system.sh`, `brew.sh`, `dev.sh` | `Clean/` one rule set per section, dry-run ledger, running-app checks |
| 3 | `lib/clean/project.sh`, `bin/purge.sh` | `Purge.swift` |
| 4 | `lib/core/apps.sh`, `lib/uninstall/*`, `app_protection.sh` `find_app_files`, `find_app_system_files`, receipts | `Uninstall/` |
| 4 | `lib/clean/apps.sh` orphan rules | `Orphans.swift` |
| 5 | `cmd/status/*` | `Status/` (CPU, memory, disk, network, battery, thermal, processes, health score) |
| 5 | `lib/optimize/*` | `Maintenance/` (tasks, catalog, outcomes) |
| 6 | `bin/installer.sh`, `bin/history.sh`, `lib/core/log.sh` oplog, `bin/touchid.sh` | `Installers.swift`, `History.swift`, `TouchID.swift` |

## Building without Xcode

The Command Line Tools on this Mac (macOS 27) can't link SwiftPM manifests, but `swiftc` works.
`Packages/MoleCore/Tools/check.sh` compiles the package sources and checks directly; `Package.swift`
stays standard so Xcode and a fixed SwiftPM build it normally.

```bash
Packages/MoleCore/Tools/check.sh            # unit tests
Packages/MoleCore/Tools/check.sh --parity   # also compare with the installed mo
```

## Phase 1 results (2026-10-17)

- 82 checks pass: 64 unit checks on temp fixtures (hard links, APFS clones made with `clonefile`,
  an edited clone, sparse files, symlinks, skipped mount folders, folded folders, protected paths,
  `CACHEDIR.TAG`, byte formatting) and 18 parity checks against Mole 1.47.1 on real folders.
- `DirectorySizer` matches `mo analyze --json` byte for byte on `~/.nvm`, `~/.rustup`, `~/.vscode`
  and `~/Documents`, including each folder's top rows. `~/Desktop` was within 0.3% while files
  changed during the run. `duSize` matches `du -skPx` exactly, and `ByteFormat` matches
  `bytes_to_human`.

### Upstream note: clones in folded folders

Mole dedupes APFS clones everywhere except in "folded" folders (`node_modules`, `.venv`, `.nvm`…),
which it sizes with `du`, so clones there count in full. On the test Mac that adds about 3.5 GB on
`~/Desktop` (8.58 GB clone-aware vs 12.11 GB Mole). The port keeps Mole's behavior by default for
parity (`foldsLikeMole: true`). `DirectorySizer(foldsLikeMole: false)` gives the physically accurate
number. Worth reporting upstream before we change the default.
