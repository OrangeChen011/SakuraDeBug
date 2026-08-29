//
//  ContentView.swift
//  SakuraDeBug
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @State private var result: JITCheckResult?
    @State private var isChecking = false
    @State private var isImportingIPA = false
    @State private var isImportingAnisette = false
    @State private var importedIPA: URL?
    @State private var importError: String?
    @State private var anisetteJSON: [String: String]?
    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var session: AppleIDSession?
    @State private var isAuthenticating = false
    @State private var authError: String?

    // JIT 开启面板状态
    @State private var isImportingPairing = false
    @State private var hasPairingFile = PairingFileStore.hasPairingFile
    @State private var isRefreshingApps = false
    @State private var apps: [String: String] = [:]
    @State private var appsError: String?
    @State private var logLines: [String] = []
    @State private var activeJITBundleID: String?
    @State private var pairingImportError: String?
    @State private var isGeneratingPairing = false
    @State private var pairingGenerateError: String?
    @ObservedObject private var selfPairing = SelfPairingController.shared
    // 局域网网页控制台
    @State private var webConsoleOn = false
    @StateObject private var webConsole = WebConsoleServer.shared
    // 内嵌 LocalDevVPN（回环隧道，免装 App Store 版 LocalDevVPN）
    @ObservedObject private var vpn = LocalDevVPNManager.shared
    // Anisette 服务器（远程拉取，免去手动导入 JSON）
    @ObservedObject private var anisette = AnisetteService.shared
    @State private var isTestingAnisette = false
    // AltSign 全流程签名 + 一键续签
    @State private var isSigning = false
    @State private var signError: String?
    @State private var signedIPA: URL?
    @State private var signingProgress: SigningProgress?
    @State private var hasSavedCredentials = false
    @State private var signingRecords: [SignedAppRecord] = []
    @State private var isResigning = false
    @State private var resignError: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sakuraBlush, .sakuraLavender], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            SakuraPetalField()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusCard
                    jitSection
                    actionButton
                    accountSection
                    ipaSection
                    resignSection
                    requirements
                }
                .padding(22)
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            hasPairingFile = PairingFileStore.hasPairingFile
            selfPairing.onLog = { line in
                appendLog(line)
            }
            // 内嵌 LocalDevVPN 日志接入
            vpn.onLog = { line in
                appendLog(line)
            }
            vpn.refreshStatus()
            // 上次崩溃残留：提示用户，便于闪退后拿到堆栈定位
            if let crash = CrashLogger.lastCrashLog() {
                appendLog("⚠️ 检测到上次崩溃记录，详情已写入 Documents/crash.log（文件共享可导出）：")
                let lines = crash.split(separator: "\n").prefix(8).map(String.init)
                for line in lines { appendLog("   \(line)") }
                CrashLogger.clearCrashLog()
            }
            // 加载已保存的凭据和签名历史
            hasSavedCredentials = KeychainService.loadCredentials() != nil
            signingRecords = SigningStore.shared.records
            // 如果有保存的 Apple ID，自动填入
            if let creds = KeychainService.loadCredentials(), appleID.isEmpty {
                appleID = creds.appleID
            }
        }
        .onChange(of: webConsoleOn) { _, on in
            if on {
                webConsole.start()
                appendLog("🌐 正在启动网页控制台（端口 8080，占用自动顺延）…")
            } else {
                webConsole.stop()
                appendLog("网页控制台已关闭")
            }
        }
        .fileImporter(isPresented: $isImportingIPA, allowedContentTypes: [.init(filenameExtension: "ipa") ?? .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                importedIPA = try IPAImportService.importIPA(from: url)
                importError = nil
            } catch { importError = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImportingAnisette, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                anisetteJSON = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
                authError = nil
            } catch { authError = "Anisette 文件读取失败：\(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $isImportingPairing, allowedContentTypes: PairingFileStore.supportedContentTypes, allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                try PairingFileStore.importFromPicker(url)
                hasPairingFile = PairingFileStore.hasPairingFile
                pairingImportError = nil
                appendLog("✅ 配对文件已导入")
                refreshApps()
            } catch { pairingImportError = "配对文件导入失败：\(error.localizedDescription)" }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("SakuraDeBug", systemImage: "bolt.horizontal.circle.fill")
                .font(.title.bold())
                .foregroundStyle(.sakuraPink)
            Text("JIT 开启器")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.sakuraInk)
            Text("开启任意已签名 App 的 JIT，签名与安装能力保留。")
                .foregroundStyle(.sakuraInk.opacity(0.6))
        }
    }

    private var statusCard: some View {
        let enabled = result?.isEnabled == true
        return HStack(spacing: 15) {
            Image(systemName: result == nil ? "questionmark" : (enabled ? "checkmark" : "xmark"))
                .font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(result == nil ? Color.sakuraPink.opacity(0.55) : (enabled ? .green : .orange), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(result == nil ? "尚未检测" : (enabled ? "本机 JIT 可用" : "本机 JIT 不可用")).font(.headline).foregroundStyle(.sakuraInk)
                Text(result?.message ?? "本机状态检测仅反映当前进程；下方面板可开启其他 App 的 JIT。").font(.subheadline).foregroundStyle(.sakuraInk.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .panelStyle()
    }

    // MARK: - JIT 开启面板

    private var jitSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("开启 JIT", subtitle: "通过配对文件 + 内嵌 LocalDevVPN 回环隧道附加调试器")
            vpnRow
            pairingRow
            selfPairingRow
            webConsoleRow
            prerequisitesRow
            refreshRow
            if let appsError {
                Text(appsError).font(.footnote).foregroundStyle(.orange)
            }
            if apps.isEmpty && !isRefreshingApps {
                Text("尚未加载 App 列表。请先导入配对文件并开启上方回环隧道，然后点击刷新。")
                    .font(.footnote).foregroundStyle(.sakuraInk.opacity(0.5))
            }
            appList
            if !logLines.isEmpty {
                logView
            }
            if let pairingImportError {
                Text(pairingImportError).font(.footnote).foregroundStyle(.red)
            }
        }
        .panelStyle()
    }

    // MARK: - 内嵌 LocalDevVPN 面板

    private var vpnRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("内嵌 LocalDevVPN", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.sakuraDeep)
                Spacer(minLength: 0)
                vpnStatusBadge
            }

            switch vpn.status {
            case .notInstalled:
                Text("开启回环隧道（10.7.0.1 → 127.0.0.1），无需再从 App Store 安装 LocalDevVPN。首次开启会弹出系统「添加 VPN 配置」授权，请选择「允许」。")
                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))
                Button {
                    vpn.enable()
                } label: {
                    Label("开启回环隧道", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink)

            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待系统 VPN 授权弹窗确认…")
                        .font(.caption).foregroundStyle(.sakuraInk.opacity(0.7))
                }

            case .installed, .disconnecting:
                Text("回环隧道已就绪但未连接，点击连接后即可开始 JIT 流程。")
                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))
                Button {
                    vpn.enable()
                } label: {
                    Label("连接回环隧道", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink)

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("回环隧道连接中…")
                        .font(.caption).foregroundStyle(.sakuraInk.opacity(0.7))
                }

            case .connected:
                VStack(alignment: .leading, spacing: 6) {
                    Label("回环隧道工作中：10.7.0.1 的连接已转发到本机 127.0.0.1", systemImage: "checkmark.seal.fill")
                        .font(.caption.bold()).foregroundStyle(.green)
                    Button {
                        vpn.disable()
                    } label: {
                        Label("关闭回环隧道", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    Button("重试") { vpn.enable() }
                        .buttonStyle(.bordered).tint(.sakuraPink).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
    }

    private var vpnStatusBadge: some View {
        let (text, color): (String, Color) = {
            switch vpn.status {
            case .connected: return ("已连接", .green)
            case .connecting, .installing: return ("连接中", .orange)
            case .installed, .disconnecting: return ("已安装", .orange)
            case .notInstalled: return ("未开启", .gray)
            case .error: return ("错误", .red)
            }
        }()
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var pairingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(
                    hasPairingFile ? "配对文件已就绪" : "未导入配对文件",
                    systemImage: hasPairingFile ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .font(.subheadline)
                .foregroundStyle(hasPairingFile ? .green : .orange)
                Spacer(minLength: 0)
                Button(hasPairingFile ? "更换" : "导入") {
                    isImportingPairing = true
                }
                .buttonStyle(.bordered).tint(.sakuraDeep).controlSize(.small)
            }
            HStack(spacing: 10) {
                Text("没有配对文件？USB 连上设备后一键生成（参考 StikPair）。")
                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.55))
                Spacer(minLength: 0)
                Button {
                    generatePairingFile()
                } label: {
                    Label(isGeneratingPairing ? "生成中…" : "USB 生成", systemImage: "arrow.triangle.branch")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink).controlSize(.small)
                .disabled(isGeneratingPairing)
            }
            if let pairingGenerateError {
                Text(pairingGenerateError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var selfPairingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("设备自配对", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.sakuraDeep)
                Spacer(minLength: 0)
                if case .showPin = selfPairing.phase {
                    Text("输入 PIN")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.sakuraPink.opacity(0.15), in: Capsule())
                        .foregroundStyle(.sakuraPink)
                }
            }
            Text("不需要电脑：SakuraDeBug 在本机伪装成配对主机（Mac），打开后到「设置 › 隐私与安全 › 开发者模式」选择 SakuraDeBug 并输入下方 PIN，配对文件自动生成。")
                .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))

            switch selfPairing.phase {
            case .idle:
                Button {
                    startSelfPairing()
                } label: {
                    Label("开始自配对", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink)
                .disabled(selfPairing.isRunning)

            case .waiting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("广播中… 请到本机「设置 › 开发者模式」选择 SakuraDeBug 并发起配对")
                        .font(.caption).foregroundStyle(.sakuraInk.opacity(0.7))
                }

            case .showPin(let pin):
                VStack(alignment: .leading, spacing: 8) {
                    Text("在「设置 › 开发者模式」中输入配对码：")
                        .font(.caption).foregroundStyle(.sakuraInk.opacity(0.7))
                    Text(pin)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.sakuraPink)
                        .tracking(8)
                    ProgressView().controlSize(.small)
                        .padding(.top, 2)
                }

            case .success:
                VStack(alignment: .leading, spacing: 6) {
                    Label("配对成功，配对文件已生成！", systemImage: "checkmark.seal.fill")
                        .font(.caption.bold()).foregroundStyle(.green)
                    if !selfPairing.deviceName.isEmpty {
                        Text("设备：\(selfPairing.deviceName)（\(selfPairing.deviceUDID)）")
                            .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))
                    }
                    HStack(spacing: 8) {
                        ShareLink(item: PairingFileStore.url) {
                            Label("分享/保存", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.sakuraPink).controlSize(.small)
                        Button {
                            refreshApps()
                        } label: {
                            Label("刷新列表", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.sakuraDeep).controlSize(.small)
                    }
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                    Button("重试") { startSelfPairing() }
                        .buttonStyle(.bordered).tint(.sakuraPink).controlSize(.small)
                }
            }
        }
    }

    private var webConsoleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("局域网网页控制台", systemImage: "globe")
                    .font(.subheadline.bold())
                    .foregroundStyle(.sakuraDeep)
                Spacer(minLength: 0)
                Toggle("", isOn: $webConsoleOn)
                    .labelsHidden()
                    .tint(.sakuraPink)
            }
            if webConsoleOn {
                if let url = webConsole.accessURL {
                    HStack(spacing: 8) {
                        Text(url)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.sakuraDeep)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Button {
                            UIPasteboard.general.string = url
                            appendLog("📋 控制台地址已复制：\(url)")
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered).tint(.sakuraPink).controlSize(.small)
                    }
                    Text("用电脑浏览器打开上面的地址，可实时查看配对状态、PIN 码、日志并下载配对文件。仅限同一 WiFi 的可信设备访问。")
                        .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("控制台启动中…")
                            .font(.caption).foregroundStyle(.sakuraInk.opacity(0.6))
                    }
                }
            } else {
                Text("开启后，同一 WiFi 下的电脑浏览器可实时查看自配对状态、PIN 码并下载配对文件。")
                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.6))
            }
        }
        .padding(.top, 2)
    }

    private var prerequisitesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("使用前提", systemImage: "list.clipboard.fill")
                .font(.caption).foregroundStyle(.sakuraInk.opacity(0.55))
            Text("① 开启上方「内嵌 LocalDevVPN」回环隧道（\(DeviceConnectionContext.defaultTargetIPAddress) → 127.0.0.1，无需另装 App）")
                .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.7))
            Text("② 目标 App 必须携带 get-task-allow（用下方 Apple ID 签名 / 开发者签名产出的即可）")
                .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.7))
        }
    }

    private var refreshRow: some View {
        Button {
            refreshApps()
        } label: {
            Label(isRefreshingApps ? "加载中…" : "刷新可开 JIT 的 App 列表", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered).tint(.sakuraDeep)
        .disabled(isRefreshingApps)
    }

    private var appList: some View {
        let sortedApps = apps.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        return Group {
            if !sortedApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sortedApps, id: \.key) { bundleID, name in
                        appRow(bundleID: bundleID, name: name)
                    }
                }
            }
        }
    }

    private func appRow(bundleID: String, name: String) -> some View {
        let isActive = activeJITBundleID == bundleID
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.bold()).foregroundStyle(.sakuraInk).lineLimit(1)
                Text(bundleID).font(.caption2).foregroundStyle(.sakuraInk.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                enableJIT(for: bundleID)
            } label: {
                Label(isActive ? "开启中…" : "开启 JIT", systemImage: "bolt.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent).tint(.sakuraPink).controlSize(.small)
            .disabled(isActive)
        }
        .padding(10)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
    }

    private var logView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.sakuraInk.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .onChange(of: logLines.count) { _, _ in
                    proxy.scrollTo(logLines.count - 1)
                }
            }
        }
        .frame(maxHeight: 160)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 检测按钮（本机）

    private var actionButton: some View {
        Button {
            isChecking = true
            result = JITManager.checkAndEnable()
            isChecking = false
        } label: {
            Label(isChecking ? "检测中..." : "检测本机 JIT 状态", systemImage: isChecking ? "arrow.triangle.2.circlepath" : "stethoscope")
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).tint(.sakuraPink).controlSize(.large).disabled(isChecking)
    }

    // MARK: - Apple ID / IPA（保留）

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Apple ID 签名", subtitle: "认证信息只用于当前签名会话")
            if let session {
                HStack {
                    Label(session.account.appleID, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.headline)
                    Spacer(minLength: 0)
                    Button("断开连接") {
                        self.session = nil
                        password = ""
                        authError = nil
                        KeychainService.clearCredentials()
                        hasSavedCredentials = false
                        appendLog("已断开 Apple ID 连接，已清除保存的凭据")
                    }
                    .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                }
            } else {
                TextField("Apple ID", text: $appleID).textInputAutocapitalization(.never).autocorrectionDisabled().inputStyle()
                SecureField("密码", text: $password).inputStyle()
                TextField("验证码（需要时填写）", text: $verificationCode).keyboardType(.numberPad).inputStyle()
                Button { authenticate() } label: {
                    Label(isAuthenticating ? "认证中..." : "连接 Apple ID", systemImage: "person.badge.key.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink)
                .disabled(isAuthenticating || appleID.isEmpty || password.isEmpty || (anisette.enabled ? anisette.serverURL.trimmingCharacters(in: .whitespaces).isEmpty : anisetteJSON == nil))
            }
            anisetteSection
            if let authError { Text(authError).font(.footnote).foregroundStyle(.orange) }
        }.panelStyle()
    }

    /// Anisette 数据来源面板：服务器（远程拉取）或文件（手动导入），二选一。
    /// 服务器模式下认证时自动从配置的 URL 实时拉取最新数据，免去每次导出。
    private var anisetteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Anisette 来源", subtitle: "Apple ID 认证必需；服务器模式自动拉取，文件模式需手动导入")

            Picker("来源", selection: $anisette.enabled) {
                Text("文件导入").tag(false)
                Text("服务器").tag(true)
            }
            .pickerStyle(.segmented)

            if anisette.enabled {
                // 服务器模式：URL 输入 + 启用提示 + 测试连接
                TextField("Anisette 服务器 URL", text: $anisette.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .inputStyle()

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isTestingAnisette = true
                            await anisette.testConnection()
                            isTestingAnisette = false
                        }
                    } label: {
                        Label(isTestingAnisette ? "测试中..." : "测试连接", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.sakuraDeep)
                    .disabled(isTestingAnisette || anisette.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let last = anisette.lastFetchDate {
                        Label("上次拉取 \(Self.timeFormatter.string(from: last))", systemImage: "checkmark.clock")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }

                if let err = anisette.lastError, let last = anisette.lastFetchDate, Date().timeIntervalSince(last) >= 60 {
                    Text("⚠️ \(err)").font(.caption2).foregroundStyle(.orange)
                } else if let err = anisette.lastError, anisette.lastFetchDate == nil {
                    Text("⚠️ \(err)").font(.caption2).foregroundStyle(.orange)
                }

                Text("提示：公共服务器易被 Apple 风控，建议自建或用可信私有地址。OTP 每次认证时实时拉取。")
                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.55))
            } else {
                // 文件模式：沿用旧的手动导入流程
                Button { isImportingAnisette = true } label: {
                    Label(anisetteJSON == nil ? "导入 Anisette JSON" : "重新导入 Anisette", systemImage: "arrow.down.doc.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).tint(.sakuraDeep)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var ipaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("IPA 签名", subtitle: "App 内 AltSign 全流程签名，无需依赖 SideStore")
            Button { isImportingIPA = true } label: {
                Label(importedIPA == nil ? "选择 IPA 文件" : "重新选择 IPA", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).tint(.sakuraDeep)
            if let importedIPA {
                Label(importedIPA.lastPathComponent, systemImage: "doc.text.fill").font(.subheadline).foregroundStyle(.sakuraInk.opacity(0.7))

                // 签名按钮：需要已选 IPA + Anisette 数据就绪
                Button { performSign() } label: {
                    HStack {
                        if isSigning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "signature")
                        }
                        Text(isSigning ? "签名中…" : "签名")
                        if let p = signingProgress, p.total > 0 {
                            Text("\(Int(Double(p.completed) / Double(p.total) * 100))%")
                                .font(.caption).foregroundStyle(.sakuraInk.opacity(0.6))
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(.sakuraPink)
                .disabled(isSigning || !anisetteReady)

                // 签名后的 IPA：发送到安装器
                if let signedIPA {
                    Divider()
                    Label(signedIPA.lastPathComponent, systemImage: "checkmark.seal.fill")
                        .font(.subheadline).foregroundStyle(.green)
                    ShareLink(item: signedIPA) {
                        Label("发送到 SideStore", systemImage: "arrow.up.forward.app.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).tint(.sakuraPink)
                }
            }
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            if let signError { Text(signError).font(.footnote).foregroundStyle(.orange) }
        }.panelStyle()
    }

    // MARK: - 一键续签

    private var resignSection: some View {
        Group {
            if let last = signingRecords.first {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("一键续签", subtitle: "记住上次签名，一键重新签名——7 天到期后续签即可继续使用")

                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise.square.fill")
                            .font(.title2).foregroundStyle(.sakuraPink)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(last.name).font(.headline).foregroundStyle(.sakuraInk)
                            Text(last.bundleID).font(.caption).foregroundStyle(.sakuraInk.opacity(0.55))
                            HStack(spacing: 8) {
                                if let days = last.daysRemaining {
                                    Label("\(days) 天", systemImage: days > 2 ? "calendar" : "calendar.badge.exclamationmark")
                                        .font(.caption2)
                                        .foregroundStyle(days > 2 ? .green : .orange)
                                }
                                Text("签名于 \(Self.dateFormatter.string(from: last.signedAt))")
                                    .font(.caption2).foregroundStyle(.sakuraInk.opacity(0.5))
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    Button { performResign() } label: {
                        HStack {
                            if isResigning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isResigning ? "续签中…" : "一键续签")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).tint(.sakuraPink)
                    .disabled(isResigning || !anisetteReady)

                    // 续签后输出
                    if let signedIPA, isResigning == false && resignError == nil {
                        ShareLink(item: signedIPA) {
                            Label("发送续签后的 IPA 到 SideStore", systemImage: "arrow.up.forward.app.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).tint(.sakuraPink)
                    }
                    if let resignError { Text(resignError).font(.footnote).foregroundStyle(.orange) }
                }
                .panelStyle()
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("使用条件", subtitle: "这些条件由 iOS 和 Apple Developer 共同决定")
            requirement("目标 App 带 get-task-allow entitlement", icon: "signature")
            requirement("内嵌 LocalDevVPN 回环隧道已开启", icon: "network")
            requirement("配对文件与设备匹配（.mobiledevicepairing）", icon: "key.fill")
            requirement("iOS 26 需保持 VPN 常开，否则 JIT 可能失效", icon: "exclamationmark.triangle.fill")
        }.panelStyle()
    }

    // MARK: - 动作

    private func startSelfPairing() {
        guard !selfPairing.isRunning else { return }
        appendLog("开始设备自配对（本机伪装为配对主机，无需电脑）…")
        selfPairing.start()
    }

    private func generatePairingFile() {
        isGeneratingPairing = true
        pairingGenerateError = nil
        appendLog("开始生成配对文件…")
        Task.detached(priority: .userInitiated) {
            do {
                try PairingGenerator.shared.generatePairingFile { line in
                    DispatchQueue.main.async { appendLog(line) }
                }
                DispatchQueue.main.async {
                    hasPairingFile = PairingFileStore.hasPairingFile
                    isGeneratingPairing = false
                    pairingGenerateError = nil
                    refreshApps()
                }
            } catch {
                DispatchQueue.main.async {
                    pairingGenerateError = error.localizedDescription
                    isGeneratingPairing = false
                    appendLog("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshApps() {
        guard hasPairingFile else {
            appsError = "请先导入配对文件。"
            return
        }
        if !vpn.isReady {
            appendLog("⚠️ 内嵌 LocalDevVPN 回环隧道未连接，App 列表刷新大概率会失败。建议先在上方开启回环隧道。")
        }
        isRefreshingApps = true
        appsError = nil
        appendLog("刷新 App 列表…")
        Task.detached(priority: .userInitiated) {
            do {
                let list = try JITEnabler.shared.getAppList(requireGetTaskAllow: true) { line in
                    DispatchQueue.main.async { appendLog(line) }
                }
                DispatchQueue.main.async {
                    apps = list
                    isRefreshingApps = false
                    appendLog("找到 \(list.count) 个可开 JIT 的 App")
                }
            } catch {
                DispatchQueue.main.async {
                    appsError = error.localizedDescription
                    isRefreshingApps = false
                    appendLog("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    private func enableJIT(for bundleID: String) {
        guard hasPairingFile else {
            appendLog("❌ 请先导入配对文件")
            return
        }
        if !vpn.isReady {
            appendLog("⚠️ 回环隧道未连接，正在自动开启内嵌 LocalDevVPN…")
            vpn.enable()
        }
        activeJITBundleID = bundleID
        Task.detached(priority: .userInitiated) {
            let ok = JITEnabler.shared.debugApp(withBundleID: bundleID) { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            DispatchQueue.main.async {
                activeJITBundleID = nil
                appendLog(ok ? "🎉 已为 \(bundleID) 开启 JIT" : "⚠️ JIT 开启失败，请查看上方日志")
            }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 300 {
            logLines.removeFirst(logLines.count - 300)
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.sakuraInk)
            Text(subtitle).font(.caption).foregroundStyle(.sakuraInk.opacity(0.55))
        }
    }

    private func authenticate() {
        isAuthenticating = true; authError = nil
        Task {
            do {
                // Anisette 数据来源：服务器模式实时拉取，文件模式用已导入的 JSON。
                // 服务器模式每次都重新拉取——OTP 每 30s 轮换，缓存会导致 -72000。
                let anisetteData: [String: String]
                if anisette.enabled {
                    anisetteData = try await anisette.fetchAnisette()
                } else {
                    guard let json = anisetteJSON else { return }
                    anisetteData = json
                }

                let authenticatedSession = try await AppleIDSigningService().authenticate(appleID: appleID, password: password, anisetteJSON: anisetteData) {
                    // 同步快照验证码：AppleIDSigningService 保证本闭包只在 MainActor 上调用。
                    // 开了双重认证的账号：先填验证码再点连接（与 AltSign/Xcode 原版逻辑一致）。
                    verificationCode.isEmpty ? nil : verificationCode
                }
                await MainActor.run {
                    session = authenticatedSession
                    // 认证成功后自动保存凭据（Keychain 加密存储），供一键续签复用
                    KeychainService.saveCredentials(appleID: appleID, password: password)
                    hasSavedCredentials = true
                    password = ""
                    isAuthenticating = false
                }
            } catch {
                await MainActor.run { authError = error.localizedDescription; isAuthenticating = false }
            }
        }
    }

    // MARK: - 签名与一键续签

    /// Anisette 数据是否就绪（签名前置条件）。
    private var anisetteReady: Bool {
        anisette.enabled
            ? !anisette.serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            : anisetteJSON != nil
    }

    /// 获取 Anisette 数据（服务器模式实时拉取，文件模式用已导入 JSON）。
    private func fetchAnisetteData() async throws -> [String: String] {
        if anisette.enabled {
            return try await anisette.fetchAnisette()
        } else {
            guard let json = anisetteJSON else {
                throw NSError(domain: "SakuraDeBug", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "请先准备 Anisette 数据"])
            }
            return json
        }
    }

    /// 执行完整签名流程（选 IPA → 签名 → 输出）。
    private func performSign() {
        guard let ipa = importedIPA else { return }

        // 密码可能在认证成功后被清空，从 Keychain 加载
        let signingID: String
        let signingPW: String
        if password.isEmpty, let creds = KeychainService.loadCredentials() {
            signingID = creds.appleID
            signingPW = creds.password
        } else {
            signingID = appleID
            signingPW = password
        }
        guard !signingID.isEmpty, !signingPW.isEmpty else {
            signError = "请先连接 Apple ID 或输入账号密码。"
            return
        }

        isSigning = true
        signError = nil
        signedIPA = nil

        Task {
            do {
                let anisetteData = try await fetchAnisetteData()
                let result = try await AppleIDSigningService().signIPA(
                    ipaURL: ipa,
                    appleID: signingID,
                    password: signingPW,
                    anisetteJSON: anisetteData,
                    verificationCode: {
                        verificationCode.isEmpty ? nil : verificationCode
                    },
                    progressHandler: { p in
                        Task { @MainActor in signingProgress = p }
                    }
                )
                await MainActor.run {
                    signedIPA = result.signedIPA
                    isSigning = false
                    signingProgress = nil
                    appendLog("✅ 签名成功：\(result.appName) (\(result.bundleID))")
                    // 保存到签名历史
                    SigningStore.shared.saveRecord(
                        signedIPA: result.signedIPA,
                        bundleID: result.bundleID,
                        name: result.appName,
                        appleID: signingID,
                        profileExpiration: result.profileExpirationDate
                    )
                    signingRecords = SigningStore.shared.records
                }
            } catch {
                await MainActor.run {
                    signError = error.localizedDescription
                    isSigning = false
                    signingProgress = nil
                    appendLog("❌ 签名失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 一键续签：加载上次签名的 IPA + 已保存凭据，自动重签名。
    /// 2FA 账号：首次续签会失败提示输入验证码，用户填后再次点击即可。
    private func performResign() {
        guard let record = signingRecords.first else { return }
        guard let creds = KeychainService.loadCredentials() else {
            resignError = "未找到已保存的凭据，请先在 Apple ID 栏重新认证。"
            return
        }

        isResigning = true
        resignError = nil
        signedIPA = nil

        Task {
            do {
                let anisetteData = try await fetchAnisetteData()
                let result = try await AppleIDSigningService().signIPA(
                    ipaURL: record.ipaURL,
                    appleID: creds.appleID,
                    password: creds.password,
                    anisetteJSON: anisetteData,
                    verificationCode: {
                        verificationCode.isEmpty ? nil : verificationCode
                    },
                    progressHandler: { p in
                        Task { @MainActor in signingProgress = p }
                    }
                )
                await MainActor.run {
                    signedIPA = result.signedIPA
                    isResigning = false
                    signingProgress = nil
                    appendLog("✅ 续签成功：\(result.appName)")
                    SigningStore.shared.saveRecord(
                        signedIPA: result.signedIPA,
                        bundleID: result.bundleID,
                        name: result.appName,
                        appleID: creds.appleID,
                        profileExpiration: result.profileExpirationDate
                    )
                    signingRecords = SigningStore.shared.records
                }
            } catch {
                await MainActor.run {
                    // 2FA 账号特殊处理：提示用户输入验证码
                    let msg = error.localizedDescription
                    if msg.contains("双重认证") || msg.contains("验证码") {
                        resignError = "需要双重认证验证码：请在上方 Apple ID 栏输入验证码后再次点击「一键续签」。"
                    } else {
                        resignError = msg
                    }
                    isResigning = false
                    signingProgress = nil
                    SigningStore.shared.markLastSignFailed()
                    signingRecords = SigningStore.shared.records
                    appendLog("❌ 续签失败：\(msg)")
                }
            }
        }
    }

    private func requirement(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.sakuraInk.opacity(0.72))
    }
}

// MARK: - 樱花飘落特效

private struct SakuraPetalField: View {
    private let petalCount = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<petalCount {
                    let seed = Double(i) * 137.508
                    let speed = 26.0 + Double(i % 6) * 9
                    let cycle = size.height + 80
                    let travel = (now * speed + seed * 47).truncatingRemainder(dividingBy: cycle)
                    let y = -40 + travel
                    let baseX = (seed * 37).truncatingRemainder(dividingBy: max(size.width, 1))
                    let x = baseX + sin(now * 1.1 + seed) * 26
                    let r = 2.6 + Double(i % 4) * 0.9
                    let rect = CGRect(x: x, y: y, width: r * 2, height: r * 2)
                    var petal = context
                    petal.opacity = 0.5 + Double(i % 3) * 0.18
                    petal.fill(Path(ellipseIn: rect), with: .color(.sakuraPetal))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(20).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.sakuraPink.opacity(0.28), lineWidth: 1))
    }

    func inputStyle() -> some View {
        padding(.horizontal, 14).padding(.vertical, 13).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(.sakuraInk)
    }
}

private extension ShapeStyle where Self == Color {
    /// 樱花粉 · 背景顶部
    static var sakuraBlush: Color { Color(red: 1.00, green: 0.89, blue: 0.92) }
    /// 淡紫 · 背景底部
    static var sakuraLavender: Color { Color(red: 0.95, green: 0.90, blue: 0.97) }
    /// 樱花粉 · 主强调色
    static var sakuraPink: Color { Color(red: 1.00, green: 0.45, blue: 0.62) }
    /// 深樱 · 次级强调色（可读性更好的文字/描边）
    static var sakuraDeep: Color { Color(red: 0.76, green: 0.29, blue: 0.47) }
    /// 樱墨 · 正文色
    static var sakuraInk: Color { Color(red: 0.37, green: 0.22, blue: 0.28) }
    /// 花瓣色 · 飘落动画
    static var sakuraPetal: Color { Color(red: 1.00, green: 0.75, blue: 0.82) }
}

#Preview {
    ContentView()
}
