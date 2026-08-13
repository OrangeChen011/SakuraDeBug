//
//  CrashLogger.swift
//  SakuraDeBug
//
//  崩溃兜底：捕获未处理异常 / 原生信号，把崩溃信息写入沙盒 Documents/crash.log。
//  下次启动时由 ContentView 检查并在日志区提示，方便真机闪退时拿到堆栈定位。
//  通过「文件」App 或 Finder 的 App 沙盒（文件共享）即可导出 crash.log。
//

import Foundation

private var crashLogPathCString: UnsafeMutablePointer<CChar>?

enum CrashLogger {

    /// 崩溃日志路径（Documents/crash.log，可通过文件共享导出）
    static var logPath: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
            + "/crash.log"
    }

    /// 在 App 启动最早阶段调用一次。
    static func install() {
        guard crashLogPathCString == nil else { return }
        crashLogPathCString = strdup(logPath)

        // Objective-C 异常（含 Swift 抛到 ObjC 桥的异常）：可安全取完整堆栈
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let text = """
            ⚠️ 未捕获异常：\(exception.name.rawValue)
            原因：\(exception.reason ?? "(无描述)")
            堆栈：
            \(stack)
            """
            try? text.write(toFile: CrashLogger.logPath, atomically: true, encoding: .utf8)
        }

        // Swift fatal error / 原生信号（force unwrap、越界、fatalError、野指针等）。
        // 信号处理器内只做 async-signal-safe 操作（POSIX open/write），记录信号号。
        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig, crashSignalHandler)
        }
    }

    /// 读取上次崩溃记录；无记录时返回 nil。
    static func lastCrashLog() -> String? {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// 启动展示后清除，避免每次启动都提示。
    static func clearCrashLog() {
        try? FileManager.default.removeItem(atPath: logPath)
    }
}

private func crashSignalHandler(_ sig: Int32) {
    if let path = crashLogPathCString {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            var msg = "SakuraDeBug 崩溃：signal=\(sig)（SIGABRT=6/SIGILL=4/SIGSEGV=11/SIGBUS=10/SIGFPE=8/SIGTRAP=5），时间 \(Date())\n"
            msg.withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
    }
    // 还原默认处理并重新抛出，让系统正常生成 .ips 崩溃报告
    signal(sig, SIG_DFL)
    raise(sig)
}
