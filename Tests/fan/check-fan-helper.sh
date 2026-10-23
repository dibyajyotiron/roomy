#!/bin/sh
# Fan helper checks on a test build (ROOMY_FAN_DRY): no root, no SMC, every fan change goes to a log in a temp folder.
# Only the recorded Roomy build may set a speed, and the fans go back to macOS when that Roomy exits, however it exits.
set -eu
cd "$(dirname "$0")/../.."
W=$(mktemp -d "${TMPDIR:-/tmp}/roomy-fan-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
xcrun swiftc -module-cache-path "$W/mc" -O -D ROOMY_FAN_DRY -module-name RoomyFan -o "$W/roomy-fan" \
  Roomy/Helper/main.swift Roomy/Sources/Engine/SMC.swift Roomy/Sources/Engine/CodeIdentity.swift
xcrun swiftc -module-cache-path "$W/mc" -O -o "$W/standin" Tests/fan/standin.swift
cp "$W/standin" "$W/other"
codesign -f -s - "$W/roomy-fan" "$W/standin" 2>/dev/null
codesign -f -s - -i other.fixture "$W/other" 2>/dev/null
export ROOMY_FAN_DIR="$W/marks" ROOMY_FAN_ALLOW="$W/allow"
mkdir "$W/marks"
n=0
check() { if [ "$1" = "$2" ]; then n=$((n + 1)); else echo "✗ $3: got [$1], expected [$2]" >&2; exit 1; fi; }
log() { [ -f "$W/marks/fans.log" ] && tr '\n' ' ' < "$W/marks/fans.log" | sed 's/ $//' || true; }

"$W/standin" "$W/roomy-fan" 0 exit whoami | cut -d' ' -f1 > "$W/allow"
check "$("$W/other" "$W/roomy-fan" 0 exit set 80 2>/dev/null)" " exit=13" "another program must not set a speed"
check "$(log)" "" "a refused request must not touch the fans"

"$W/standin" "$W/roomy-fan" 2 crash set 80 >/dev/null 2>&1 || true
sleep 1.5
check "$(log)" "set 80 auto" "the fans must go back to macOS when the allowed Roomy crashes"
check "$(ls "$W/marks" | grep -c watch || true)" "0" "the watcher must clean up after itself"

: > "$W/marks/fans.log"
cat > "$W/twice.sh" <<SH
"$W/roomy-fan" set 60 && "$W/roomy-fan" set 90 && sleep 1
SH
# /bin/sh isn't the allowed build, so allow it for this one check: two sets from one process, one watcher.
# "; :" keeps the shell from replacing itself with the command, so the caller really is the shell.
SH_HASH=$(/bin/sh -c "\"$W/roomy-fan\" whoami; :")
printf '%s\n' "$SH_HASH" > "$W/allow"; : > "$W/marks/fans.log"
/bin/sh "$W/twice.sh"
sleep 1
check "$(log)" "set 60 set 90 auto" "two speed changes from one Roomy must leave one watcher that hands back once"

printf '%s\n' 0000000000000000000000000000000000000000 > "$W/allow"
check "$("$W/standin" "$W/roomy-fan" 0 exit set 80 2>/dev/null)" " exit=13" "an allow file for another build must refuse"
printf 'x; rm -rf /\n' > "$W/allow"
check "$("$W/standin" "$W/roomy-fan" 0 exit set 80 2>/dev/null)" " exit=13" "an allow file that isn't a hash must refuse"
rm "$W/allow"
check "$("$W/standin" "$W/roomy-fan" 0 exit set 80 2>/dev/null)" " exit=13" "no allow file must refuse"
echo "Fan helper: $n passed (test build, no root, no fans touched)"
