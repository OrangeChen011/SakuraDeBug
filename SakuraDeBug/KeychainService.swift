//
//  KeychainService.swift
//  SakuraDeBug
//
//  安全存储 Apple ID + 密码到 iOS Keychain（加密，不落明文文件）。
//  一键续签时从此处加载凭据，用户无需每次重新输入。
//

import Foundation
import Security

/// Keychain 封装：存储 Apple ID 账号与密码。
///
/// 密码是敏感信息，**绝不**写入 UserDefaults 或明文文件——
/// 只能存 Keychain（iOS 硬件级加密，App 卸载后自动清除）。
enum KeychainService {

    private static let service = "com.sakuradebug.appleid"

    // MARK: - Password

    /// 将密码安全写入 Keychain（account 为 Apple ID 邮箱）。
    @discardableResult
    static func savePassword(_ password: String, for account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 先删旧值再写新值，避免 duplicate item 错误
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从 Keychain 读取密码。
    static func loadPassword(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定账号的密码。
    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Apple ID

    /// Apple ID（邮箱）不是敏感信息，存 UserDefaults 即可；
    /// 但密码必须存 Keychain。这里同时管理两者的保存与加载。
    static func saveCredentials(appleID: String, password: String) {
        UserDefaults.standard.set(appleID, forKey: "savedAppleID")
        savePassword(password, for: appleID)
    }

    /// 加载已保存的凭据（Apple ID + 密码）。
    /// 返回 nil 表示没有保存过或密码已被删除。
    static func loadCredentials() -> (appleID: String, password: String)? {
        guard let appleID = UserDefaults.standard.string(forKey: "savedAppleID"),
              let password = loadPassword(for: appleID),
              !password.isEmpty else { return nil }
        return (appleID, password)
    }

    /// 清除已保存的凭据（断开连接 / 退出登录时调用）。
    static func clearCredentials() {
        if let appleID = UserDefaults.standard.string(forKey: "savedAppleID") {
            deletePassword(for: appleID)
        }
        UserDefaults.standard.removeObject(forKey: "savedAppleID")
    }
}
