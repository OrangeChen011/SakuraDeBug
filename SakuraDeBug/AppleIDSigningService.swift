//
//  AppleIDSigningService.swift
//  SakuraDeBug
//

import Foundation
import AltSign

enum AppleIDSigningError: LocalizedError {
    case invalidApplication
    case invalidAnisette
    case noTeam
    case certificateLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidApplication:
            return "IPA 中没有找到有效的 App bundle。"
        case .invalidAnisette:
            return "Anisette JSON 无效，请导入 SideStore/AltServer 导出的 Anisette 数据。"
        case .noTeam:
            return "Apple ID 未关联任何开发者团队。请确认账号已在 developer.apple.com 注册。"
        case .certificateLimitReached:
            return "开发者证书数量已达上限，且自动清理失败。请到 developer.apple.com 手动删除旧证书后重试。"
        }
    }
}

struct AppleIDSession {
    let account: ALTAccount
    let session: ALTAppleAPISession
}

struct SigningProgress {
    let completed: Int64
    let total: Int64
}

/// 签名完成后的结果。
struct SignIPAResult {
    let signedIPA: URL
    let bundleID: String
    let appName: String
    /// provisioning profile 过期时间（免费账号 7 天后到期）。
    let profileExpirationDate: Date?
}

final class AppleIDSigningService {
    func authenticate(
        appleID: String,
        password: String,
        anisetteJSON: [String: String],
        verificationCode: @escaping () -> String?
    ) async throws -> AppleIDSession {
        guard let anisetteData = ALTAnisetteData(json: anisetteJSON) else {
            throw AppleIDSigningError.invalidAnisette
        }

        return try await withCheckedThrowingContinuation { continuation in
            // 线程安全防重入：AltSign 的完成回调可能从多个后台线程触发
            // （2FA 失败路径、验证码验证完成、递归认证等）。普通 Bool 标志在
            // data race 下可能双双通过 guard，导致 continuation 被 resume 两次，
            // withCheckedThrowingContinuation 会直接崩溃——认证类 App 最经典的闪退源。
            let lock = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<AppleIDSession, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            ALTAppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData,
                xcodeVersion: "16.3 (16E140)",
                verificationHandler: { handler in
                    // AltSign 在 URLSession 后台线程同步调用本闭包，期望我们拿到
                    // 验证码后立即回调。这里同步读取验证码快照（主线程取值），
                    // 不创建跨线程 Task、不挂起——彻底消除时序类崩溃。
                    // 无验证码时回调 nil → AltSign 报"需要双重认证"，UI 提示先填码。
                    let code = Self.readVerificationCodeSnapshot(verificationCode)
                    handler(code)
                }
            ) { account, session, error in
                if let account, let session {
                    resumeOnce(.success(AppleIDSession(account: account, session: session)))
                } else {
                    resumeOnce(.failure(Self.translatedAuthError(error ?? AppleIDSigningError.invalidAnisette)))
                }
            }
        }
    }

    /// 从主线程同步读取验证码快照。
    /// AltSign 的 verificationHandler 在后台线程调用；同步跳主线程取值，
    /// 若恰在主线程则直接取，避免 DispatchQueue.main.sync 自我死锁。
    /// 传入的 read 闭包由调用方保证只在主线程被调用（读取 @State 安全）。
    private static func readVerificationCodeSnapshot(_ read: () -> String?) -> String? {
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync { read() }
    }

    func sign(
        appURL: URL,
        team: ALTTeam,
        certificate: ALTCertificate,
        provisioningProfiles: [ALTProvisioningProfile],
        progressHandler: @escaping (SigningProgress) -> Void
    ) async throws {
        guard ALTApplication(fileURL: appURL) != nil else {
            throw AppleIDSigningError.invalidApplication
        }

        let signer = ALTSigner(team: team, certificate: certificate)
        // 显式标注 CheckedContinuation<Void, Error>：resume() 的 Void 特例在
        // 嵌套函数内不会反向推断 T（Swift 类型推断限制，GUI Xcode 实测报
        // "Generic parameter 'T' could not be inferred"），显式指定即可消除。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 与 authenticate 相同的线程安全防重入（签名进度回调 + 完成回调
            // 可能从多个线程触发，双重 resume 会闪退）
            let lock = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            let progress = signer.signApp(
                at: appURL,
                provisioningProfiles: provisioningProfiles
            ) { success, error in
                if success {
                    resumeOnce(.success(()))
                } else {
                    resumeOnce(.failure(error ?? AppleIDSigningError.invalidApplication))
                }
            }

            progressHandler(SigningProgress(
                completed: progress.completedUnitCount,
                total: progress.totalUnitCount
            ))
        }
    }

    // MARK: - 全流程签名（一键续签核心）

    /// 完整的 AltSign 签名流程：认证 → 获取团队 → 创建证书 →
    /// 解压 IPA → 注册 AppID → 获取 Profile → 签名 → 打包。
    ///
    /// 这是 NB助手 式「一键续签」的核心——在 App 内完成全部签名步骤，
    /// 不依赖 SideStore。签名后的 IPA 可直接发送给安装器。
    func signIPA(
        ipaURL: URL,
        appleID: String,
        password: String,
        anisetteJSON: [String: String],
        verificationCode: @escaping () -> String?,
        progressHandler: @escaping (SigningProgress) -> Void
    ) async throws -> SignIPAResult {

        // 1. 认证
        let authSession = try await authenticate(
            appleID: appleID,
            password: password,
            anisetteJSON: anisetteJSON,
            verificationCode: verificationCode
        )

        // 2. 获取开发者团队（免费账号通常只有一个）
        let teams = try await fetchTeamsAsync(
            account: authSession.account,
            session: authSession.session
        )
        guard let team = teams.first else {
            throw AppleIDSigningError.noTeam
        }

        // 3. 创建开发证书（带自动清理：达上限时吊销最旧的再重试）
        let certificate = try await fetchOrCreateCertificate(
            team: team,
            session: authSession.session
        )

        // 4. 解压 IPA 到临时工作目录
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SakuraDeBug-Sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let appBundleURL = try FileManager.default.unzipAppBundle(
            at: ipaURL,
            toDirectory: workDir
        )

        // 5. 读取 App 信息（bundleID、名称）
        guard let application = ALTApplication(fileURL: appBundleURL) else {
            throw AppleIDSigningError.invalidApplication
        }
        let bundleID = application.bundleIdentifier
        let appName = application.name

        // 6. 注册 / 查找 App ID
        let appIDs = try await ALTAppleAPI.shared.fetchAppIDs(
            for: team, session: authSession.session
        )
        let appID: ALTAppID
        if let existing = appIDs.first(where: { $0.bundleIdentifier == bundleID }) {
            appID = existing
        } else {
            appID = try await ALTAppleAPI.shared.addAppID(
                withName: appName,
                bundleIdentifier: bundleID,
                team: team,
                session: authSession.session
            )
        }

        // 7. 获取 provisioning profile
        let profile = try await ALTAppleAPI.shared.fetchProvisioningProfile(
            for: appID,
            deviceType: .iPhone,
            team: team,
            session: authSession.session
        )

        // 8. AltSign 签名（ldid + entitlements + mobileprovision）
        try await sign(
            appURL: appBundleURL,
            team: team,
            certificate: certificate,
            provisioningProfiles: [profile],
            progressHandler: progressHandler
        )

        // 9. 重新打包为 IPA
        let signedIPA = try FileManager.default.zipAppBundle(at: appBundleURL)

        return SignIPAResult(
            signedIPA: signedIPA,
            bundleID: bundleID,
            appName: appName,
            profileExpirationDate: profile.expirationDate
        )
    }

    // MARK: - AltSign 异步包装（补全 AltSign 缺少的 async 变体）

    /// fetchTeams 的 async 包装（AltSign 只提供了 completion handler 版）。
    private func fetchTeamsAsync(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchTeams(
                for: account,
                session: session
            ) { teams, error in
                if let teams {
                    continuation.resume(returning: teams)
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.noTeam)
                }
            }
        }
    }

    /// addCertificate 的 async 包装。
    private func addCertificateAsync(
        machineName: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTCertificate {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.addCertificate(
                machineName: machineName,
                to: team,
                session: session
            ) { certificate, error in
                if let certificate {
                    continuation.resume(returning: certificate)
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.certificateLimitReached)
                }
            }
        }
    }

    /// fetchCertificates 的 async 包装。
    private func fetchCertificatesAsync(
        for team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTX509Certificate] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchCertificates(
                for: team,
                session: session
            ) { certificates, error in
                if let certificates {
                    continuation.resume(returning: certificates)
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.certificateLimitReached)
                }
            }
        }
    }

    /// revoke 的 async 包装。
    private func revokeCertificateAsync(
        _ certificate: ALTX509Certificate,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ALTAppleAPI.shared.revoke(
                certificate,
                for: team,
                session: session
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.certificateLimitReached)
                }
            }
        }
    }

    /// 创建开发证书：先尝试新建，若达上限（tooManyCertificates）则
    /// 自动吊销最旧的证书后重试——与 AltStore/SideStore 同款策略。
    private func fetchOrCreateCertificate(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTCertificate {
        do {
            return try await addCertificateAsync(
                machineName: "SakuraDeBug",
                team: team,
                session: session
            )
        } catch {
            // 检查是否为证书上限错误
            let isLimit = (error as? ALTAppleAPIError == .tooManyCertificates)
                || (error as NSError).domain == ALTAppleAPIErrorDomain
                   && ALTAppleAPIError(rawValue: (error as NSError).code) == .tooManyCertificates

            guard isLimit else { throw error }

            // 吊销最旧的证书后重试
            let certs = try await fetchCertificatesAsync(for: team, session: session)
            guard let oldest = certs.min(by: { $0.creationDate < $1.creationDate }) else {
                throw AppleIDSigningError.certificateLimitReached
            }
            try await revokeCertificateAsync(oldest, team: team, session: session)

            return try await addCertificateAsync(
                machineName: "SakuraDeBug",
                team: team,
                session: session
            )
        }
    }

    /// 把 AltSign 透传的 Apple GSA 服务端原始错误翻译成可行动的中文提示。
    ///
    /// -72000 是 Apple 认证服务器（gsa.apple.com）返回的拒绝码，常见于 Anisette
    /// 数据过期/无效，或账号被 Apple 临时风控——而不是密码错误：SRP 握手（init/complete）
    /// 能走到完成才报 -72000，说明密码与账号本身是有效的。
    private static func translatedAuthError(_ error: Error) -> Error {
        // AltSign 自身的 2FA 错误：明确引导用户先填验证码再重试
        if let altError = error as? ALTAppleAPIError {
            switch altError {
            case .requiresTwoFactorAuthentication:
                return NSError(
                    domain: "SakuraDeBug", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "需要双重认证验证码：请在「验证码」栏输入设备上收到的 6 位验证码后，重新点击「连接 Apple ID」。"])
            case .incorrectVerificationCode:
                return NSError(
                    domain: "SakuraDeBug", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "验证码错误：请核对设备上显示的最新 6 位验证码后重试。"])
            default:
                break
            }
        }

        let nsError = error as NSError
        guard nsError.domain == ALTUnderlyingAppleAPIErrorDomain else { return error }

        let raw = nsError.localizedDescription
        let code = nsError.code

        if code == -72000 {
            let message = """
            Apple 认证被拒绝（-72000）
            原因：Anisette 数据已过期/无效，或账号被 Apple 临时风控（与密码无关）。
            解决：
            ① 重新从 SideStore/AltServer 导出最新 Anisette JSON 并重新导入（每次认证前都应重新导出）；
            ② 关闭 VPN / 代理后重试；
            ③ 确认该 Apple ID 能在 appleid.apple.com 正常登录；
            ④ 若仍失败，等待 15-60 分钟再试（短时间内多次失败会触发风控）。
            Apple 原始信息：\(raw)
            """
            return NSError(
                domain: nsError.domain, code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        return NSError(
            domain: nsError.domain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "Apple 认证失败（\(code)）：\(raw)"])
    }
}
