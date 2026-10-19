# Notices

Roomy is licensed under the **GNU General Public License v3.0** (see `LICENSE`). It builds on these
open-source projects:

## Mole (GPL-3.0)

Roomy cleans with [Mole](https://github.com/tw93/mole) by tw93 and contributors. A copy of Mole
(its scripts and helper binaries, unmodified except that the entry script finds its files relative
to itself) is bundled inside Roomy.app under `Contents/Resources/mole`, with Mole's licence. Its
source is at https://github.com/tw93/mole. Parts of Mole's cleaning, disk-analysis and safety logic
are also ported to Swift in `Packages/MoleCore`; each ported file names its Mole source.

Mole asks forks to use a distinct name and to credit Mole as the upstream source. Roomy does not use
the Mole name, logo or artwork, or the design of the Mole desktop app.

## Stats (MIT)

Fan readings and fan control in `Roomy/Sources/Engine/SMC.swift` (used by the app and its
`roomy-fan` helper) are adapted from the SMC module of [Stats](https://github.com/exelban/stats)
by Serhiy Mytrovtsiy, used under the MIT License. Its notice is kept in `LICENSES/Stats-MIT.txt`.

## Sparkle (MIT)

Roomy updates itself with [Sparkle](https://sparkle-project.org), vendored unchanged in `Vendor/Sparkle` with its
licence.

## Pow (MIT) and Poly Haven (CC0)

Effects use [Pow](https://github.com/EmergeTools/Pow) (MIT, vendored in `Vendor/Pow` with its
licence). The living room's models, textures and lighting are CC0 scans from
[Poly Haven](https://polyhaven.com); see `Roomy/Resources/Room/CREDITS.md`.
