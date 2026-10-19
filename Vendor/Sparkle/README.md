# Sparkle 2.10.0

[Sparkle](https://sparkle-project.org) (MIT, see `LICENSE`) updates Roomy itself. These files come unchanged from the
official release `Sparkle-2.10.0.tar.xz` (SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`,
from https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0), except that the XPC services are left out
because Roomy isn't sandboxed.

- `Sparkle.framework` is embedded in Roomy.app by `Roomy/build.sh` and signed with it.
- `bin/generate_keys` makes the update signing key once. Its private half stays in the macOS Keychain.
- `bin/sign_update` signs each release's zip (`Roomy/release.sh` runs it).
