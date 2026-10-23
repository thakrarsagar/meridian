import AppKit
import Security
import CryptoKit
import NetworkExtension

enum Credentials {
    // Stable storage identity preserves credentials entered in the first local preview.
    private static let service = "io.github.thakrarsagar.nordlet.ikev2"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] }

    static func load() throws -> (username: String, reference: Data)? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecReturnPersistentRef as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = result as? [String: Any], let username = attributes[kSecAttrAccount as String] as? String,
              let reference = attributes[kSecValuePersistentRef as String] as? Data else {
            throw error("Keychain did not return a credential reference. Save your service credentials again.")
        }
        return (username, reference)
    }

    static func save(username: String, password: String) throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, username.utf8.count <= 256,
              !password.isEmpty, password.utf8.count <= 1024 else {
            throw error("Enter your Nord service username and password.")
        }
        let values: [String: Any] = [kSecAttrAccount as String: username, kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: "Meridian IKEv2 service credentials", kSecAttrAccess as String: try vpnAccess()]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status != errSecItemNotFound { try check(status); return }

        let item = query.merging(values) { _, new in new }
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    static func vpnAccess() throws -> SecAccess {
        var trusted: [SecTrustedApplication] = []
        for path in [Bundle.main.executablePath!, "/usr/libexec/neagent", "/usr/libexec/nesessionmanager", try providerPath()] {
            var application: SecTrustedApplication?
            let result = path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
            try check(result)
            if let application { trusted.append(application) }
        }
        var access: SecAccess?
        try check(SecAccessCreate("Meridian IKEv2 service credentials" as CFString, trusted as CFArray, &access))
        return access!
    }

    static func prepareForConnection() throws -> (username: String, reference: Data)? {
        guard let saved = try load() else { return nil }
        // Repair only this entry's read policy; do not read its secret or replace its reference.
        var result: CFTypeRef?
        try check(SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: saved.reference, kSecReturnRef as String: true] as CFDictionary, &result))
        guard let result else { throw error("Keychain did not return the saved credential item.") }
        let item = result as! SecKeychainItem
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(item, &access))
        guard let access else { throw error("Keychain did not return the credential access policy.") }
        if try allowVPNProvider(in: access) { try check(SecKeychainItemSetAccess(item, access)) }
        return saved
    }

    static func allowVPNProvider(in access: SecAccess) throws -> Bool {
        var provider: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(try providerPath(), &provider))
        var expected: CFData?
        try check(SecTrustedApplicationCopyData(provider!, &expected))
        guard let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL], !acls.isEmpty else {
            throw error("The saved credential has no readable Keychain access policy. Update credentials in Settings.")
        }
        // One existing decrypt rule already granting access is sufficient. Preserve other rules.
        for acl in acls {
            var apps: CFArray?; var description: CFString?; var prompt = SecKeychainPromptSelector()
            try check(SecACLCopyContents(acl, &apps, &description, &prompt))
            if apps == nil { return false }
            for app in apps as? [SecTrustedApplication] ?? [] {
                var data: CFData?
                try check(SecTrustedApplicationCopyData(app, &data))
                if data! as Data == expected! as Data { return false }
            }
        }
        let acl = acls[0]
        var apps: CFArray?; var description: CFString?; var prompt = SecKeychainPromptSelector()
        try check(SecACLCopyContents(acl, &apps, &description, &prompt))
        guard let description else { throw error("Keychain did not return the credential policy description.") }
        var trusted = apps as? [SecTrustedApplication] ?? []
        trusted.append(provider!)
        try check(SecACLSetContents(acl, trusted as CFArray, description, prompt))
        return true
    }

    private static func providerPath() throws -> String {
        guard let url = Bundle(for: NEVPNProtocolIKEv2.self).builtInPlugInsURL?
            .appendingPathComponent("NEIKEv2Provider.appex/Contents/MacOS/NEIKEv2Provider"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw error("macOS's IKEv2 credential reader is unavailable. Meridian left your saved credentials unchanged.")
        }
        return url.path
    }

    static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw error((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain operation failed (\(status)).") }
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "Meridian", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum NordCertificate {
    static let download = URL(string: "https://downloads.nordcdn.com/certificates/root.der")!
    static let guide = URL(string: "https://support.nordvpn.com/hc/en-us/articles/19921536696977-How-to-connect-to-NordVPN-with-IKEv2-IPSec-on-macOS")!
    // Official root.der measured on 2026-10-24. Rotation requires review and a new build.
    static let fingerprint = "8b5a495db498a6c2c8ca7af6ae4a5cdf65e689d06cbeccb02453c91c3191e2ff"

    static func install(_ data: Data) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint, let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw Credentials.error("Nord's certificate differs from the reviewed certificate. Open Nord's setup guide instead.")
        }
        var existing: CFArray?
        let read = SecTrustSettingsCopyTrustSettings(certificate, .user, &existing)
        guard read == errSecItemNotFound || read == errSecNoTrustSettings || (read == errSecSuccess && (existing as? [Any])?.isEmpty == true) else {
            throw Credentials.error("This certificate already has custom trust settings. Meridian left them unchanged. Review them in Keychain Access using Nord's guide.")
        }
        let added = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary, nil)
        if added != errSecDuplicateItem { try Credentials.check(added) }
        guard let eap = SecPolicyCreateWithProperties(kSecPolicyAppleEAP, nil),
              let ipsec = SecPolicyCreateWithProperties(kSecPolicyAppleIPsec, nil) else {
            throw Credentials.error("macOS could not create the VPN certificate policies.")
        }
        let settings: [[String: Any]] = [eap, ipsec].map { policy in
            [kSecTrustSettingsPolicy as String: policy, kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue]
        }
        try Credentials.check(SecTrustSettingsSetTrustSettings(certificate, .user, settings as CFArray))
    }
}
