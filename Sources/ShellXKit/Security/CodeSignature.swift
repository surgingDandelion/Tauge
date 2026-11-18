import Foundation
import Security

/// How the running app was signed.
public enum CodeSignature {
    /// True when the app is ad-hoc signed (`codesign --sign -`), which is what
    /// the build script falls back to when no signing identity is installed.
    ///
    /// The login keychain pins an "Always Allow" grant to the app's code
    /// signature. An ad-hoc signature's designated requirement is the cdhash,
    /// and the cdhash changes on every build, so each rebuild silently revokes
    /// every grant and macOS asks for the login-keychain password again. A
    /// stable identity keeps the requirement — and therefore the grant — across
    /// rebuilds.
    public static var isAdHoc: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & 0x2 != 0
    }
}
