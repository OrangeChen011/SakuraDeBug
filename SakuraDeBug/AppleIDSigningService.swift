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
                if let account, let session {
                    continuation.resume(returning: AppleIDSession(account: account, session: session))
                } else {
                    continuation.resume(throwing: error ?? AppleIDSigningError.invalidAnisette)
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
            let progress = signer.signApp(
                at: appURL,
                provisioningProfiles: provisioningProfiles
            ) { success, error in
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
}
