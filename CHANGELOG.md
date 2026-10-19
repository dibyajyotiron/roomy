# Changelog

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
