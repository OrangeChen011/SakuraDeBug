//
//  SigningStore.swift
//  SakuraDeBug
//
//  签名历史持久化：保存上次签名的 IPA 副本 + 元数据，
//  供「一键续签」直接复用，免去重新选 IPA、输账号密码的流程。
//
//  IPA 文件存到 Documents/Resigned/（App 沙箱持久区域），
//  元数据存 UserDefaults（JSON 编码）。
//

import Foundation

/// 单条签名记录的元数据。
struct SignedAppRecord: Codable, Equatable {
    let bundleID: String
    let name: String
    let ipaFileName: String      // Documents/Resigned/ 下的文件名
    let appleID: String
    let signedAt: Date
    /// provisioning profile 的过期时间（签名 7 天后到期）。
    let profileExpirationDate: Date?
    /// 上次签名是否成功（用于续签时判断）。
    var lastSignSucceeded: Bool

    /// IPA 文件完整路径。
    var ipaURL: URL {
        SigningStore.resignedDir.appendingPathComponent(ipaFileName)
    }

    /// 是否即将过期（剩余 < 2 天）。
    var isExpiringSoon: Bool {
        guard let exp = profileExpirationDate else { return false }
        return exp.timeIntervalSinceNow < 2 * 24 * 3600
    }

    /// 剩余天数（向下取整，已过期返回 0）。
    var daysRemaining: Int? {
        guard let exp = profileExpirationDate else { return nil }
        let secs = exp.timeIntervalSinceNow
        return secs > 0 ? Int(secs / 86400) : 0
    }
}

/// 签名历史管理：单例，最多保留 5 条记录。
final class SigningStore {

    static let shared = SigningStore()

    /// IPA 持久存储目录。
    static var resignedDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resigned", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let key = "signingHistory"
    private let maxRecords = 5

    private init() {}

    // MARK: - Read

    /// 所有签名记录（按时间倒序）。
    var records: [SignedAppRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SignedAppRecord].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.signedAt > $1.signedAt }
    }

    /// 最近一条签名记录（一键续签用）。
    var lastRecord: SignedAppRecord? {
        records.first
    }

    // MARK: - Write

    /// 保存一条签名记录，并把签名后的 IPA 副本复制到持久目录。
    /// - Parameters:
    ///   - signedIPA: 签名完成后的 IPA 临时文件 URL
    ///   - bundleID: App Bundle Identifier
    ///   - name: App 显示名
    ///   - appleID: 签名用的 Apple ID
    ///   - profileExpiration: provisioning profile 过期时间
    func saveRecord(
        signedIPA: URL,
        bundleID: String,
        name: String,
        appleID: String,
        profileExpiration: Date?
    ) {
        // 复制 IPA 到持久目录（覆盖同名）
        let fileName = "\(bundleID.replacingOccurrences(of: ".", with: "_"))-\(Int(Date().timeIntervalSince1970)).ipa"
        let dest = Self.resignedDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)  // 覆盖同名
        do {
            try FileManager.default.copyItem(at: signedIPA, to: dest)
        } catch {
            // 复制失败不致命，记录仍保存（IPA 路径指向临时文件）
        }

        let record = SignedAppRecord(
            bundleID: bundleID,
            name: name,
            ipaFileName: fileName,
            appleID: appleID,
            signedAt: Date(),
            profileExpirationDate: profileExpiration,
            lastSignSucceeded: true
        )

        var list = records.filter { $0.bundleID != bundleID }  // 去重
        list.insert(record, at: 0)
        if list.count > maxRecords {
            // 删除最旧的记录对应的 IPA 文件
            for old in list.dropFirst(maxRecords) {
                try? FileManager.default.removeItem(at: old.ipaURL)
            }
            list = Array(list.prefix(maxRecords))
        }
        save(list)
    }

    /// 标记最近一条记录签名失败（续签失败时调用）。
    func markLastSignFailed() {
        guard !records.isEmpty else { return }
        var list = records
        list[0].lastSignSucceeded = false
        save(list)
    }

    // MARK: - Delete

    /// 删除指定记录及其 IPA 文件。
    func deleteRecord(_ record: SignedAppRecord) {
        try? FileManager.default.removeItem(at: record.ipaURL)
        let list = records.filter { $0 != record }
        save(list)
    }

    /// 清空所有记录和 IPA 文件。
    func clearAll() {
        for r in records {
            try? FileManager.default.removeItem(at: r.ipaURL)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Private

    private func save(_ records: [SignedAppRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
