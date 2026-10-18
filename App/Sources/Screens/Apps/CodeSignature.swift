import Foundation
import Security

/// Who signed an app, read with the Security framework from the bundle on disk.
struct CodeSignature: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case apple, appStore, developerID, otherSigned, adHoc, unsigned
    }

    var kind: Kind
    var teamID: String?
    /// Common name of the leaf certificate, e.g. "Developer ID Application: Example Inc (ABCDE12345)".
    var authority: String?

    var label: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: "Developer ID"
        case .otherSigned: "Signed"
        case .adHoc: "Ad hoc signature"
        case .unsigned: "Unsigned"
        }
    }

    /// Reads the signature of the code at `url` (a bundle or executable). Slow-ish: call off the main thread.
    static func read(url: URL) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return CodeSignature(kind: .unsigned)
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return CodeSignature(kind: .unsigned) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        var authority: String?
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            var cn: CFString?
            if SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess { authority = cn as String? }
        }
        guard dict[kSecCodeInfoCertificates as String] != nil else {
            // Signed without a certificate chain.
            return CodeSignature(kind: dict[kSecCodeInfoIdentifier as String] == nil ? .unsigned : .adHoc, teamID: team)
        }
        let kind: Kind = if satisfies(code, "anchor apple") { .apple }
            else if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]") { .appStore }
            else if satisfies(code, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]") { .developerID }
            else { .otherSigned }
        return CodeSignature(kind: kind, teamID: team, authority: authority)
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        // Basic validation only: hashing every resource of a large bundle (Xcode) takes seconds.
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), req) == errSecSuccess
    }
}
