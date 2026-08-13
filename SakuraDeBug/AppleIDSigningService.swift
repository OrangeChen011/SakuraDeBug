//
//  AppleIDSigningService.swift
//  SakuraDeBug
//

import Foundation
import AltSign

enum AppleIDSigningError: LocalizedError {
    case invalidApplication
    case invalidAnisette

    var errorDescription: String? {
        switch self {
        case .invalidApplication:
            return "IPA 中没有找到有效的 App bundle。"
        case .invalidAnisette:
            return "Anisette JSON 无效，请导入 SideStore/AltServer 导出的 Anisette 数据。"
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
        try await withCheckedThrowingContinuation { continuation in
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
