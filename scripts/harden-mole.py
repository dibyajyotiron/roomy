#!/usr/bin/env python3
"""Apply Roomy's explicit no-administrator policy to its private, pinned Mole copy."""
import pathlib
import sys

POLICY = '''
# ROOMY_SECURITY_POLICY_V1: no implicit sudo, including cached credentials.
# Do not use MOLE_TEST_NO_AUTH: it also changes upstream deletion protections.
sudo() { printf '%s\\n' 'Roomy does not authorize administrator cleanup.' >&2; return 1; }
readonly -f sudo
export -f sudo
'''


AUTH_FUNCTIONS = ('_request_password', 'request_sudo_access', 'request_sudo_access_with_password',
                  'has_sudo_session', 'adopt_sudo_session', 'request_sudo',
                  'ensure_sudo_session', 'ensure_sudo_session_with_password')


def harden(root):
    base = root / 'libexec/lib/core/base.sh'
    source = base.read_text()
    anchor = 'readonly MOLE_BASE_LOADED=1\n'
    if source.count(anchor) != 1 or 'ROOMY_SECURITY_POLICY_V1' in source:
        raise ValueError('Unexpected Mole base; review the policy before building')
    # All bundled shells load base.sh. Reject future alternate privilege paths.
    for script in (root / 'libexec').rglob('*.sh'):
        text = script.read_text()
        commands = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        if 'command sudo' in commands or 'env sudo' in commands:
            raise ValueError(f'Unreviewed sudo bypass: {script}')
        if '/usr/bin/sudo' in text:
            # Upstream uses these only to drop root to SUDO_USER. Roomy never starts Mole as root;
            # deny them as well, so this policy does not depend on the upstream caller's guard.
            text = text.replace('/usr/bin/sudo', 'sudo')
            script.write_text(text)
    auth = root / 'libexec/lib/core/sudo.sh'
    auth_source = auth.read_text()
    for function in AUTH_FUNCTIONS:
        start = function + '() {\n'
        if auth_source.count(start) != 1:
            raise ValueError(f'Unexpected Mole authorization function: {function}')
        auth_source = auth_source.replace(start, start + '    return 1 # Roomy: no prompt or cached authorization\n')
    auth.write_text(auth_source)
    safety = 'declare -a SAFETY_WHITELIST_PATTERNS=(\n'
    if source.count(safety) != 1:
        raise ValueError('Unexpected Mole safety whitelist; review before building')
    protected = ''.join(f'    "$HOME/{name}"\n    "$HOME/{name}/*"\n' for name in
                        ['.ssh', '.aws', '.gnupg', '.kube', 'Library/Keychains',
                         'Library/Mobile Documents', 'Library/CloudStorage'])
    protected += '    "$HOME/.wget-hsts"\n    "$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2*"\n'
    source = source.replace(safety, safety + protected)
    base.write_text(source.replace(anchor, anchor + POLICY))


if __name__ == '__main__':
    harden(pathlib.Path(sys.argv[1]))
