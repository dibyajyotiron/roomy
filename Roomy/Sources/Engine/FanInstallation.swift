import Foundation

/// Verification happens on a root-private snapshot, after authorization and before any setuid bit is set.
/// The cdhash comes from the running Roomy, not from the potentially replaceable app on disk.
enum FanInstallation {
    static func command(bundle: String, callerHash: String) -> String? {
        guard CodeIdentity.isHash(callerHash), bundle.hasPrefix("/"), !bundle.contains("\0") else { return nil }
        return """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        umask 077
        base=/Library/PrivilegedHelperTools
        [ ! -L "$base" ]
        /bin/mkdir -p "$base"
        [ "$(/usr/bin/stat -f %u "$base")" = 0 ]
        [ "$(/usr/bin/find "$base" -prune -perm +022 -print)" = "" ]
        stage=$(/usr/bin/mktemp -d "$base/.roomy-install.XXXXXXXX")
        trap '/bin/rm -rf "$stage"' EXIT
        /usr/bin/ditto \(Shell.quote(bundle)) "$stage/Roomy.app"
        [ ! -L "$stage/Roomy.app/Contents" ]
        [ ! -L "$stage/Roomy.app/Contents/MacOS" ]
        [ ! -L "$stage/Roomy.app/Contents/MacOS/roomy-fan" ]
        /usr/bin/codesign --verify --deep --strict -R \(Shell.quote("=cdhash H\"" + callerHash + "\"")) "$stage/Roomy.app"
        /usr/bin/install -o root -g wheel -m 0755 "$stage/Roomy.app/Contents/MacOS/roomy-fan" "$stage/helper"
        /usr/bin/printf '%s\\n' \(Shell.quote(callerHash)) > "$stage/client"
        /bin/chmod 644 "$stage/client"
        /bin/mv -f "$stage/client" "$base/app.roomy.fan.client"
        /bin/chmod 4755 "$stage/helper"
        /bin/mv -f "$stage/helper" "$base/app.roomy.fan"
        """
    }
}
