import Foundation
import Security

public final class KeychainCredentialProvider: CredentialProvider {
    private let service = "com.yourname.keyboardwtf"
    private let account = "openai-api-key"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedAPIKey: String?

    // The ad-hoc development build has no stable Apple signing identity, so
    // macOS can re-ask for the Keychain item whenever the executable changes.
    // Keep a local, user-owned cache after the one-time Keychain migration so
    // normal launches and API calls do not repeatedly trigger that prompt.
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var cacheKey: String { "keyboard.wtf.credentials.\(service).\(account)" }
    private var migrationAttemptedKey: String { "keyboard.wtf.credentials.migration-attempted.\(service).\(account)" }

    public func apiKey() throws -> String? {
        if let environment = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !environment.isEmpty { return environment }
        lock.lock(); defer { lock.unlock() }
        if let cachedAPIKey, !cachedAPIKey.isEmpty { return cachedAPIKey }
        if let cached = defaults.string(forKey: cacheKey), !cached.isEmpty {
            cachedAPIKey = cached
            return cached
        }
        // Only attempt the legacy Keychain migration once. If the user denied
        // the prompt, subsequent requests fail cleanly instead of prompting on
        // every Realtime/Responses call. Saving a new key resets this marker.
        guard !defaults.bool(forKey: migrationAttemptedKey) else { return nil }
        defaults.set(true, forKey: migrationAttemptedKey)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw AppError.authentication }
        cachedAPIKey = value
        defaults.set(value, forKey: cacheKey)
        return value
    }

    public func save(apiKey: String) throws {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AppError.authentication }
        lock.lock(); defer { lock.unlock() }
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            // The local cache is deliberately written even when a rebuilt
            // ad-hoc executable cannot update the old Keychain ACL. This lets
            // the user continue without another password dialog; the next
            // stable-signed build can still migrate the item normally.
            _ = SecItemAdd(insert as CFDictionary, nil)
        }
        cachedAPIKey = clean
        defaults.set(clean, forKey: cacheKey)
        defaults.set(true, forKey: migrationAttemptedKey)
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.authentication }
        cachedAPIKey = nil
        defaults.removeObject(forKey: cacheKey)
        defaults.removeObject(forKey: migrationAttemptedKey)
    }
}
