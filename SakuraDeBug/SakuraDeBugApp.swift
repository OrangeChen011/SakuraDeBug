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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
