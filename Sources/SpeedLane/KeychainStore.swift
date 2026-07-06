import Foundation
import Security

/// 服务器密码存取(macOS 钥匙串),以服务器 UUID 作为账户名
enum KeychainStore {
    private static let service = "SpeedLane"
    /// 项目更名前使用的服务名,用于读取时自动迁移
    private static let legacyService = "GitHubFast"

    private static func baseQuery(service: String, id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private static func baseQuery(for id: UUID) -> [String: Any] {
        baseQuery(service: service, id: id)
    }

    static func setPassword(_ password: String, for id: UUID) {
        let query = baseQuery(for: id)
        guard !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func password(for id: UUID) -> String? {
        if let password = read(service: service, id: id) {
            return password
        }
        // 旧服务名下存过的密码:读到后迁移到新服务名
        if let password = read(service: legacyService, id: id) {
            setPassword(password, for: id)
            SecItemDelete(baseQuery(service: legacyService, id: id) as CFDictionary)
            return password
        }
        return nil
    }

    private static func read(service: String, id: UUID) -> String? {
        var query = baseQuery(service: service, id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }
}
