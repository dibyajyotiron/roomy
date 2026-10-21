# Changelog

## 0.2.3

- The round button's loader is a ring of liquid light around it, flowing while a clean runs and filling as a scan
  goes, instead of a spinner inside. The button keeps its colour while it works, its glass is flatter and softer, and
  the glow around it is subtler and more blended.
- Security fixes from an independent review:
  - Your Trash stays protected, and now fails safe: Roomy puts only `~/.Trash` on Mole's keep list for each scan and
    clean, reads it back to confirm, and if it can't, Mole doesn't run. The list is restored exactly afterwards.
  - Checkup runs Mole's own clean as it is: no per-item exclusions it couldn't guarantee, and no extra cleaning pass
    of Roomy's own. Its review shows Mole's findings; Mole checks everything again when it cleans.
  - Signing: Full Disk Access is tied to each exact build of Roomy, so no other app can borrow it. macOS may ask you
    to grant it again after an update.
  - The Terminal install checks a release manifest signed with Roomy's release key (it needs Apple's Command Line
    Tools for that, and installs nothing without them), stages the new app and keeps the old one until it's in place.
  - Git is run with repository hooks switched off, Homebrew names are validated before they reach Terminal, and a
    file that can't be read fully is never counted as a duplicate.
  - AI Cleanup checks again, just before removing anything, that the tool isn't running or updating, and worktrees
    need a fresh, clean `git status`.
  - Mole is fetched from a pinned source with checked helper digests, and a release is published only after its
    uploaded files and the exact commit's CI are verified.
- An item that's already gone when you clean (another clean removed it) counts as done, not as a failure, and every
  list drops what no longer exists.
- Old Claude Code extensions for VS Code are offered only once VS Code itself no longer uses them.

## 0.2.2

- About, copyright and credits now name only what Roomy actually uses: Mole, Stats, Sparkle, Pow and Poly Haven.

## 0.2.1

- Startup Items, rebuilt to match System Settings › Login Items & Extensions. Open at Login, then Allow in the
  Background grouped by app or developer, each with its real state, read from launchd without a password. Read
  Full List adds what only macOS's own list has (apps' background tasks, developer names); macOS asks for an
  administrator's password first, and Roomy only reads it. Helpers that can't run (an unreadable file, a program
  that's gone) and helpers switched off with launchctl behind System Settings' back are listed first.
- Only actions that work are offered: Remove for your own launch agents (to the Trash), Turn Back On for what
  launchctl switched off, and System Settings for the rest. The old switches turned helpers off with launchctl,
  which System Settings never showed, so they're gone.

## 0.2.0

- A new look. Each area has its own colours, which run through the whole window: the ground, icons, rows and
  buttons. Pick "By area" or a single colour in Settings. The sidebar is an icon rail with instant labels, and the
  lists use larger icons and rounder rows.
- One round button, half outside the bottom of the window, scans and then cleans on every screen. It stays in place
  and glows softly. Every screen opens on its own page: a large icon, what it looks at, then the scan and the
  results, with removal right there. Screens you've already scanned open on their results.
- Checkup's room: each piece of clutter is picked out and thrown into one black bag that's full when the scan ends,
  books go back on the shelf, and Clean drops the bag in the bin.
- Checkup finds more, safely: copies of updates apps already downloaded (Squirrel and Sparkle), and the caches of
  sandboxed apps, only for apps that are still installed and not running. Open apps are listed as "Quit to include",
  and everything is checked again just before it's removed.
- The menu bar: Free Up for memory and disk, battery health with its cycle count and how much you've used since the
  last full charge, and Keep awake and Keep screen on that say what they're doing.
- Maintenance runs Mole's own `mo optimize` with Mole's defaults, and lists each task in plain words first.
- Updates are checked every 10 minutes and when you come back to Roomy, and Settings has Check Now.
- Safety fixes:
  - **App Slimming no longer removes apps.** In 0.1.1 and 0.1.2, removing an app's language files moved the whole
    app to the Trash. It's now review-only, and nothing inside an app or an Applications folder can be removed
    except by the Uninstaller, or by you in Disk Map.
  - **Checkup never empties the Trash.** Roomy now keeps `~/.Trash` on Mole's keep list for every scan and clean,
    and never counts what's in the Trash as junk.

## 0.1.2

- Checkup's result shows what was really freed again. Mole 1.61 changed how it logs a clean, so Roomy read
  "Freed 0 B, 0 items" after cleans that freed gigabytes. Roomy now reads both formats, and History entries
  recorded as zero are corrected from Mole's log. Roomy also checks every Mole release for this before it ships.
- Leftovers of a removed app are found where Mole finds them: its helpers (`<id>.helper`, `<id>.ShipIt`…),
  macOS's hidden per-user caches and its recent-documents list. An app moved to the Trash counts as removed even
  if it keeps a spare copy of itself in its own data folder, and an app put back from the Trash leaves Leftovers.
- Rescan on every screen that scans (⇧⌘R): Leftovers, Storage, Disk Map, AI Cleanup, Duplicates and the rest
  scan just their part again, and anything already gone drops off the list.

## 0.1.1

- Leftovers are found the moment you remove an app. Roomy remembers your apps and watches the Trash and the
  Applications folders; when an app goes, it looks where that app's name and bundle ID point (its Library folders
  and `~/.config`, `~/.cache`, `~/.local/share` folders), adds what's there to Leftovers and sends a notification
  with how much it left. Apps removed while Roomy was closed are caught at the next scan. No list of known apps:
  it works the same for every app.
- A folder a same-named command-line tool still uses (like `~/.config/opencode` while the `opencode` command is
  installed) is never listed.
- Caches and logs of a removed app start selected; its settings and data wait for you to choose.
- Roomy's own files no longer show up as leftovers.

## 0.1.0

- Install from Terminal in one line, with no Open Anyway step:
  `curl -fsSL https://raw.githubusercontent.com/dibyajyotiron/roomy/main/scripts/install.sh | sh`.
  It checks the download against the release's SHA-256 checksum and leaves Roomy owned by you, so updates never
  need a password.
- New update button. When a new Roomy is out, a ringed download button appears in the sidebar just above your disk.
  One click downloads it, then Roomy quits, installs it and reopens. Nothing downloads before you click.
- Mole no longer updates itself. Roomy uses only the Mole bundled inside it, the version each release is tested
  with; a newer Mole arrives in a Roomy release. Mole copies older Roomy versions downloaded are removed.
- Fixed: a scan could show every cleanup category empty if a Mole update ran at the same time.
- More accurate totals: a folder and something inside it (like `~/Library/Caches/Google` and Chrome's cache in it)
  are counted once, so Roomy's total matches Mole's own.
- Mail Attachments and Trash are separate screens.
- Clean shows a live "Cleaning…" capsule with the time so far, instead of a greyed-out button.
- Reads Mole's newer "review it yourself" lines (Rust toolchains, Docker data, build artifacts).

## 0.0.1 – 0.0.3

Early previews: Checkup with the living room, Review before cleaning, the cleanup modules, Uninstaller, Leftovers,
Disk Map, Large & Old Files, Duplicates, Similar Photos, Activity with fan control, Storage, Protection, History,
the menu bar panel, the installer and self-updates.
