import Foundation
import Security

/// Minimal Keychain wrapper for storing the Claude API key on device.
enum KeychainStore {
    private static let service = "edu.yale.yudw.shelfmark"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AppSettings {
    static let apiKeyAccount = "anthropic-api-key"

    static var apiKey: String {
        get { KeychainStore.get(apiKeyAccount) ?? "" }
        set { KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount) }
    }

    /// Claude model used to read spines. Stored in UserDefaults so it can be changed in Settings.
    static var model: String {
        get { UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-opus-5-5" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeModel") }
    }

    /// Reasoning effort for spine identification: low / medium / high.
    static var effort: String {
        get { UserDefaults.standard.string(forKey: "claudeEffort") ?? "medium" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeEffort") }
    }
}
