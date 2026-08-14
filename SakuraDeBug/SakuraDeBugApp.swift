//
//  SakuraDeBugApp.swift
//  SakuraDeBug
//

import SwiftUI

@main
struct SakuraDeBugApp: App {
    init() {
        // 尽早安装崩溃兜底：闪退时写入 Documents/crash.log，供下次启动提示
        CrashLogger.install()
        // 注册后台任务：用户切到「设置 › 开发者模式」配对时保持 App 存活
        SelfPairingController.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
