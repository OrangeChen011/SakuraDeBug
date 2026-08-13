//
//  JITManager.swift
//  SakuraDeBug
//

import Foundation
import Darwin

struct JITCheckResult: Equatable {
    let isEnabled: Bool
    let message: String
}

enum JITManager {
    private static let pageSize = 4096

    /// 检测当前进程是否具备 JIT 条件（本机诊断用）。
    static func checkAndEnable() -> JITCheckResult {
        let memory = mmap(
            nil,
            pageSize,
            PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_PRIVATE | MAP_ANON | MAP_JIT,
            -1,
            0
        )

        guard memory != MAP_FAILED else {
            return JITCheckResult(
                isEnabled: false,
                message: "无法申请可执行内存。请使用支持 JIT 的签名，并通过调试器或 JIT 工具启动本 App。"
            )
        }

        munmap(memory, pageSize)
        return JITCheckResult(
            isEnabled: true,
            message: "可执行内存申请成功，当前进程已具备 JIT 条件。"
        )
    }

    /// 为指定 bundleID 的 App 开启 JIT（配对文件 + LocalDevVPN 回环隧道 + debugserver 附加）。
    @discardableResult
    static func enableJIT(for bundleID: String, logger: @escaping (String) -> Void) -> Bool {
        JITEnabler.shared.debugApp(withBundleID: bundleID, logger: logger)
    }

    /// 列出设备上可开启 JIT 的 App（带 get-task-allow entitlement）。
    static func jitCapableApps(logger: @escaping (String) -> Void = { _ in }) throws -> [String: String] {
        try JITEnabler.shared.getAppList(requireGetTaskAllow: true, logger: logger)
    }
}
