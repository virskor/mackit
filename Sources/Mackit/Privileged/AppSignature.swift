import Foundation
import Security

/// The running app's own designated code-signing requirement.
///
/// The privileged helper authenticates its XPC clients against the
/// authorized-client list recorded at install time — one designated
/// requirement per app install that has installed the daemon — so the
/// daemon serves exactly those installs, whatever signing identity
/// each carries. Reading the app's *designated requirement* rather than
/// composing a requirement string by hand is what makes this work under
/// both signing modes the build produces:
///
/// - a Developer ID build's designated requirement pins the app's
///   identifier and signing team, and is stable across rebuilds, so a
///   Sparkle update keeps the installed helper authorized;
/// - an ad-hoc development build's designated requirement is the code
///   directory hash of its own binary, which changes on every rebuild —
///   and is exactly as it should be: a helper installed by one build
///   refuses the next build's connection, which the app detects as an
///   unreachable helper and repairs by reinstalling.
///
/// A build that is not signed at all yields no designated requirement,
/// which the install step reports as a failure rather than installing a
/// daemon that would refuse every connection.
enum AppSignature {
    /// The running app's designated requirement as a requirement-language
    /// string, or nil when the app carries no readable signature.
    static func designatedRequirement() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            return nil
        }
        // Round-trip the string before handing it to the install: a
        // requirement the requirement language cannot parse would be
        // recorded into the daemon plist and make the daemon refuse
        // every connection, which is a failure better surfaced here.
        var reparsed: SecRequirement?
        guard SecRequirementCreateWithString(text, [], &reparsed) == errSecSuccess else {
            return nil
        }
        return text as String
    }
}
