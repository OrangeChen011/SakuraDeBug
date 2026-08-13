//
//  ContentView.swift
//  SakuraDeBug
//

import SwiftUI
import UniformTypeIdentifiers

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
            sectionTitle("开启 JIT", subtitle: "通过配对文件 + LocalDevVPN 回环隧道附加调试器")
            pairingRow
            selfPairingRow
            prerequisitesRow
            refreshRow
            if let appsError {
                Text(appsError).font(.footnote).foregroundStyle(.orange)
            }
            if apps.isEmpty && !isRefreshingApps {
                Text("尚未加载 App 列表。请先导入配对文件并开启 LocalDevVPN，然后点击刷新。")
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
                    Button {
                        refreshApps()
                    } label: {
                        Label("刷新 App 列表", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.sakuraDeep).controlSize(.small)
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

    private var prerequisitesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("使用前提", systemImage: "list.clipboard.fill")
                .font(.caption).foregroundStyle(.sakuraInk.opacity(0.55))
            Text("① 设备安装并开启 LocalDevVPN（App Store 免费，回环地址 \(DeviceConnectionContext.defaultTargetIPAddress)）")
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
                        appendLog("已断开 Apple ID 连接，可重新输入账号密码")
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
                .disabled(isAuthenticating || appleID.isEmpty || password.isEmpty || anisetteJSON == nil)
            }
            Button { isImportingAnisette = true } label: {
                Label(anisetteJSON == nil ? "导入 Anisette JSON" : "重新导入 Anisette", systemImage: "arrow.down.doc.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).tint(.sakuraDeep)
            if let authError { Text(authError).font(.footnote).foregroundStyle(.orange) }
        }.panelStyle()
    }

    private var ipaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("IPA 签名", subtitle: "通过 AltSign 重签名，完成后交给安装器")
            Button { isImportingIPA = true } label: {
                Label(importedIPA == nil ? "选择 IPA 文件" : "重新选择 IPA", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).tint(.sakuraDeep)
            if let importedIPA {
                Label(importedIPA.lastPathComponent, systemImage: "doc.text.fill").font(.subheadline).foregroundStyle(.sakuraInk.opacity(0.7))
                ShareLink(item: importedIPA) {
                    Label("发送到 SideStore", systemImage: "arrow.up.forward.app.fill").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(.sakuraPink)
            }
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
        }.panelStyle()
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("使用条件", subtitle: "这些条件由 iOS 和 Apple Developer 共同决定")
            requirement("目标 App 带 get-task-allow entitlement", icon: "signature")
            requirement("LocalDevVPN 回环隧道已开启", icon: "network")
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
        guard let anisetteJSON else { return }
        isAuthenticating = true; authError = nil
        Task {
            do {
                let authenticatedSession = try await AppleIDSigningService().authenticate(appleID: appleID, password: password, anisetteJSON: anisetteJSON) {
                    verificationCode.isEmpty ? nil : verificationCode
                }
                await MainActor.run { session = authenticatedSession; password = ""; isAuthenticating = false }
            } catch {
                await MainActor.run { authError = error.localizedDescription; isAuthenticating = false }
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
