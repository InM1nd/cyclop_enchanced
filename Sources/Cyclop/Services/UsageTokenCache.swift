import Foundation
import LocalAuthentication
import Security

/// Keychain reads of Claude's and Cursor's items pop a password dialog for
/// any app that is not already on the item's ACL — and an ad-hoc rebuild
/// looks like a new app every time. The dialog is suppressed; a successful
/// read is cached in Cyclop's own folder so the next visit never asks.
enum UsageTokenCache {
    private static let url = Support.file("usage-tokens.json")

    static var claude: String? { read("claude") }
    static var cursor: String? { read("cursor") }

    static func storeClaude(_ token: String) { write("claude", token) }
    static func storeCursor(_ token: String) { write("cursor", token) }
    static func clearClaude() { write("claude", nil) }
    static func clearCursor() { write("cursor", nil) }

    /// `allowPrompt` is the last resort — once, then the bytes live in the
    /// cache file and Keychain is not asked again.
    static func keychain(service: String, account: String? = nil, allowPrompt: Bool) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func read(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = json[key], !token.isEmpty
        else { return nil }
        return token
    }

    private static func write(_ key: String, _ token: String?) {
        var json = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: String]
        } ?? [:]
        if let token, !token.isEmpty {
            json[key] = token
        } else {
            json.removeValue(forKey: key)
        }
        if json.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
