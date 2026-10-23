import Foundation
import Security

/// Which exact build of a program is running, by its code signature. Shared by Roomy and roomy-fan: Roomy records its
/// own identity when you allow fan control, and the helper sets a speed only for a caller with that identity whose
/// signature still checks out right now. With ad-hoc signing the identity is the code-directory hash (cdhash), so it
/// names one build: after a Roomy update, fan control is allowed again once.
enum CodeIdentity {
    /// The cdhash of a valid, running program, as lowercase hex; nil if it isn't signed or its signature doesn't
    /// check out at this moment (tampered with, or its pages no longer match).
    static func cdhash(of code: SecCode) -> String? {
        guard SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let hash = dict[kSecCodeInfoUnique as String] as? Data, hash.count >= 20 else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// This program's own identity.
    static func ownCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return cdhash(of: code)
    }

    /// The identity of the running process `pid`.
    static func cdhash(pid: pid_t) -> String? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return cdhash(of: code)
    }

    /// A cdhash as written in the allow file: hex only, so it can't carry anything else.
    static func isHash(_ s: String) -> Bool {
        (40...64).contains(s.count) && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
