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
        verificationCode: @escaping () async -> String?
    ) async throws -> AppleIDSession {
        guard let anisetteData = ALTAnisetteData(json: anisetteJSON) else {
            throw AppleIDSigningError.invalidAnisette
        }

        return try await withCheckedThrowingContinuation { continuation in
            // 防重入：AltSign 完成回调若异常触发两次，第二次 resume 会导致
            // withCheckedThrowingContinuation 崩溃（经典闪退源），这里加锁保护。
            var resumed = false
            ALTAppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData,
                xcodeVersion: "16.3 (16E140)",
                verificationHandler: { handler in
                    Task {
                        handler(await verificationCode())
                    }
                }
            ) { account, session, error in
                guard !resumed else { return }
                resumed = true
                if let account, let session {
                    continuation.resume(returning: AppleIDSession(account: account, session: session))
                } else {
                    continuation.resume(throwing: Self.translatedAuthError(error ?? AppleIDSigningError.invalidAnisette))
                }
            }
        }
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
            var resumed = false
            let progress = signer.signApp(
                at: appURL,
                provisioningProfiles: provisioningProfiles
            ) { success, error in
                guard !resumed else { return }
                resumed = true
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.invalidApplication)
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
