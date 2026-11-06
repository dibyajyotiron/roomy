# Roomy security audit — 6 November 2026

Source baseline: `35dcbca88c648a03cbb6d420f9848bfcf5daba90` (0.2.5). Proposed fix: 0.2.6.

## Conclusion and scope

The reviewed Roomy code did not reveal an intentional remote backdoor, telemetry collector, general-purpose root command service, or hidden login persistence. That is a source-review finding, not a guarantee that every binary or this Mac is malware-free. Cleaner applications are not inherently viruses; broad filesystem access and privileged helpers make implementation defects consequential.

Reviewed Roomy's process execution, cleaning and Trash operations, cached scan actions, diagnostics, fan helper, startup controls, updater, installation/release scripts, CI configuration, dependency manifests and selected security-sensitive paths in bundled Mole 1.61.0. Reviewed Sparkle's published advisories and the vendored framework's version and dynamic dependencies. Did not reverse-engineer all third-party binaries or review every line of upstream Mole/Pow. `upstream-puremac` is not an input to Roomy's release build and is outside this audit's shipped-code scope.

## Findings and changes

Severity is qualitative and assumes an attacker can supply local inputs or modify user-writable files. No remote exploit or actual compromise was demonstrated.

| Finding | Risk | Change and evidence |
|---|---|---|
| Production diagnostics accepted an arbitrary Mole executable path; other diagnostics exported local data to caller-selected paths. | High: abuse Roomy's filesystem permissions. | Self-test accepts only the authenticated bundled engine. Export/render probes and automatic-install test preference are debug-only. Initialize diagnostic handling before the app model. |
| Subprocesses inherited shell startup scripts, interpreter options, exported functions, Git/Mole overrides and user PATH. | High: unintended code execution or changed safety policy. | Environment allowlist and system-first fixed PATH; explicit safe Git settings also reach Mole. Fixture startup script is not executed. |
| Cached CLI-uninstall arrays reached process execution without a command allowlist. | High: modified cache could describe arbitrary code. | Accept only supported tool/package combinations and the exact reviewed worktree path. Disable npm lifecycle scripts. Regression tests reject arbitrary shell commands. |
| Bundled scripts were executed without checking their resource seal; a missing bundle fell back to `mo` on PATH. | High: substituted code could inherit Roomy's access. | Validate the complete bundle against the running executable's code hash before engine calls; remove PATH fallback. This narrows exposure but is not an atomic filesystem snapshot: concurrent same-user modification remains a limitation. |
| Fan helper installation copied a user-writable executable directly into a setuid-root destination. | High: substitution during administrator authorization. | Copy the whole bundle into a root-private directory, verify its seal against the running app's code hash, then install from that protected copy. Fixtures reject a modified nested helper and a separately re-signed replacement app. No live privileged installation was performed. |
| Internal `watch` command accepted arbitrary callers/PIDs; watcher startup was not acknowledged before the setting process exited. | Medium: root process/resource abuse and unreliable fan reset. | Restrict it to the helper's own signed parent and real-root caller; validate PID; use a bounded readiness handshake. Do not set fans when startup fails. Dry tests cover unauthorized callers, crash reset and repeated changes. |
| Mole could adopt cached sudo authorization despite Roomy's user-only cleanup promise. | Medium: unintended administrator cleanup. | Apply a small reviewed build-time policy denying sudo, including absolute sudo calls. Do not enable upstream test mode, which changes unrelated protections. Fixture verifies neither the parent nor child Bash shell invokes a fake sudo. |
| Maintenance could clear download-history records; cleanup removed wget's HSTS state. | Medium: loss of useful security metadata. | Mandatory Mole keep rules preserve QuarantineEventsV2, wget HSTS, credential stores and synced data even with a custom keep list. This does not claim the old operation disabled Gatekeeper itself. |
| Manual Empty Trash followed a substituted `.Trash` directory; native path rules did not protect credential/sync trees and other users' descendants comprehensively. | High for unintended deletion. | Descriptor-relative traversal uses no-follow opens and unlink operations. Tests preserve targets outside Trash and reject a symlinked root. Native path checks add credentials, cloud folders, other accounts and resolved root guards. |
| Package postinstall recursively changed ownership through a public application path. | High: local path substitution during root installation. | Package installations stay root-owned. Terminal installer sets ownership within its private stage before moving the app into place. Package updates may now need administrator approval. Privileged installer execution was not tested live. |
| Ad-hoc builds omitted Hardened Runtime; unused SwiftPM preview/debug dependencies remained declared; scan history directory used default permissions. | Hardening/privacy. | Enable runtime protection; helper has no runtime exceptions. Ad-hoc app/Sparkle require the library-validation exception because they have no Team ID. Developer ID builds retain validation. Remove preview dependencies; make Roomy's support directory private to its owner. |
| README overstated the release workflow and automatic fix delivery. | Assurance/documentation. | Explain that post-publication CI is detection, users must install updates, and repository rules are independent controls. |

## Dependencies and supply chain

- Mole is pinned to commit `122bf83cb433a5e194a7af62ee9fb4c78ef3cc26` (1.61.0), with repository-pinned source/helper SHA-256 values. CI fetches and checks these. `scripts/harden-mole.py` applies the documented Roomy policy only to the bundled copy and rejects an unexpected source layout. This audit did not upgrade upstream Mole.
- Vendored Sparkle reports 2.10.0. The reviewed [published advisory list](https://github.com/sparkle-project/Sparkle/security/advisories) and [security changes](https://sparkle-project.github.io/documentation/security-and-reliability/) place the listed 2026 fixes before 2.10.0. This is not an exhaustive vulnerability-database or binary reproducibility attestation.
- Existing Ed25519 update signatures, pre-extraction verification, signed release manifest, pinned release key, artifact digests and exact-commit publishing checks remain in place. The signing key was not exported or printed.
- No private-key headers, AWS access-key patterns or GitHub token patterns were found in the scanned tracked text files. This is a limited pattern scan, not a history-wide secret audit.
- Source review found normal GitHub update traffic and explicit third-party tool operations, not data-upload logic. Network traffic was not packet-captured. Service operators still see normal connection metadata.

## Verification and release status

Local verification uses temporary fixtures; no real cleanup, root-helper installation, fan-speed changes or system-security setting changes were performed.

- MoleCore: 64 checks passed.
- SecurityChecks: 33 checks passed.
- Python release and Mole-policy tests: 18 passed.
- Fan helper: 10 dry checks passed, including deliberate fixture crashes.
- Helper-install identity boundary: 3 checks passed.
- Hardened Runtime/Sparkle fixture: loads correctly; altered bundled resource rejected (2 checks).
- Ed25519 fixture: valid signature accepted; modified payload rejected.
- Shell syntax and Git whitespace checks passed.

Full local application compilation was blocked by the execution environment: Xcode's Swift macro plugin cannot invoke `sandbox-exec` (`sandbox_apply: Operation not permitted`). No attempt was made to disable that isolation. CI compilation/package verification is required before release. Version 0.2.6 and release notes are prepared; this document is not evidence that a release has been published.

## Remaining limits and rollout

Roomy still has broad optional Full Disk Access and is not App Sandbox confined. Authorized external Homebrew/npm tooling is another trust boundary. Native Finder trash operations and bundle validation are not designed to withstand all simultaneous same-user filesystem races. A compromised maintainer account, signing key or build machine is outside the protection of ordinary cleanup guards. The HTTPS first-install script also needs to be trusted independently of the signed archive it verifies.

Ad-hoc signing is not Apple Developer ID signing or notarization. Its explicit library-validation exception is a residual limitation; the other Hardened Runtime protections remain enabled. A future Developer ID release can eliminate that exception. Corporate device policy can reasonably disallow this level of access even for non-malicious software.

An already installed fan helper is outside the app bundle. Updating source or the app does not replace it automatically: users must authorize the new helper through Roomy or use Roomy's removal control. The previously installed helper on the audit machine was left unchanged. Final distribution must use a clean source commit, passing CI and the existing signed-release validation; never publish a locally incomplete build.
