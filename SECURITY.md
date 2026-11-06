# Security

Roomy deletes files, so safety bugs matter. Please don't open a public issue for a security problem.

**Report privately:** on GitHub, open the repository's **Security** tab and choose **Report a vulnerability**. Only the
maintainer sees the report. Please include the Roomy version (Settings › Updates), your macOS version, and how to
reproduce it.

Worth reporting: anything that removes or offers to remove files it shouldn't, ways to make Roomy install an update
that wasn't signed by its maintainer, privilege problems in the `roomy-fan` helper, and anything that sends data off
your Mac.

Only the latest release gets fixes. Users must install the offered update to receive a fix; publishing alone does not patch an existing installation. If fan control was enabled, authorize the updated helper from Roomy after updating (or remove it from Roomy's settings).

Roomy is not sandboxed and Full Disk Access is broad. Cleaning does not require root. The optional fan helper is an explicitly installed setuid program with a narrow command interface, not a general-purpose shell or network service. Ad-hoc builds are not Apple-notarized; their Hardened Runtime uses a library-validation exception for Sparkle because ad-hoc signatures have no Team ID. Developer ID builds keep library validation enabled.

The November 2026 source audit and verification limits are recorded in [docs/SECURITY_AUDIT_2026-11-06.md](docs/SECURITY_AUDIT_2026-11-06.md).
