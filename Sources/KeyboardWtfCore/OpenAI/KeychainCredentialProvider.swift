import Foundation
import Security

public final class KeychainCredentialProvider: CredentialProvider {
    private let service = "com.yourname.keyboardwtf"
    private let account = "openai-api-key"
    public init() {}

    public func apiKey() throws -> String? {
        if let environment = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !environment.isEmpty { return environment }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw AppError.authentication }
        return value
    }

    public func save(apiKey: String) throws {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AppError.authentication }
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AppError.authentication }; return
        }
        guard status == errSecSuccess else { throw AppError.authentication }
    }

    public func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.authentication }
    }
}
