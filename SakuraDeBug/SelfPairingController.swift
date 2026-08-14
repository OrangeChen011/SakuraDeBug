//
//  SelfPairingController.swift
//  SakuraDeBug
//
//  设备自配对：本机伪装成 PairableHost（Mac 主机），通过 NetService 广播
//  `_remotepairing-pairable-host._tcp.` 服务，用户到「设置 › 开发者模式」
//  里与本机配对并输入 PIN，配对文件直接生成到标准位置，全程不经过电脑。
//  移植自 StikDebug/StikPair 的 PairingController（裁剪掉 Apple TV / 后台任务 / keepalive）。
//
//  注意：配对列表 UI 需要 iOS 27+（StikPair 同款依赖），iOS 26 及以下的
//  开发者模式页面没有 PairableHost 配对入口。
//

import Foundation
import Network
import StikPairFFI

@MainActor
final class SelfPairingController: ObservableObject {

    static let shared = SelfPairingController()

    private init() {
        netServiceDelegate.onLog = { [weak self] line in self?.log(line) }
        netServiceDelegate.onPublishFailed = { [weak self] line, code in
            self?.log(line)
            self?.handlePublishFailure(code: code)
        }
    }

    enum Phase: Equatable {
        case idle
        case waiting            // 广播中，等待设备在设置里发起配对
        case showPin(String)    // 需要用户在「设置 › 开发者模式」输入 PIN
        case success            // 配对完成，配对文件已写入
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var deviceName = ""
    @Published private(set) var deviceUDID = ""

    /// 日志回调（由 ContentView 绑定到日志区，方便排查）
    var onLog: ((String) -> Void)?

    private let bindAddress = "0.0.0.0"
    private let hostName = "SakuraDeBug"
    private let hostModel = "Mac17,7"

    private var netService: NetService?
    private let netServiceDelegate = NetServiceDelegateObject()
    private(set) var isRunning = false

    /// 待广播参数（C 库就绪回调后缓存，失败重试时复用）
    private struct PendingPublish {
        let serviceID: String
        let port: Int32
        let txt: [String: Data]
    }
    private var pendingPublish: PendingPublish?
    /// 当前广播尝试次数（0 起；超过 maxPublishAttempts 判失败）
    private var publishAttempt = 0
    /// 广播失败自动重试上限（mDNS 名字冲突 -72001 / 网络瞬断可自愈）
    private let maxPublishAttempts = 3
    /// -72000 连续失败计数（≥2 次判定为 AP 隔离，给出针对性提示）
    private var apiFailureCount = 0

    var isAdvertising: Bool { netService != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        phase = .waiting
        deviceName = ""
        deviceUDID = ""
        apiFailureCount = 0
        log("开始设备自配对（本机伪装为 Mac 配对主机，无需电脑）…")

        Task {
            // iOS 14+ 必须先获得本地网络权限，否则 NetService 广播会静默失败。
            // 注意：只有权限弹窗出现并允许后，「设置 › 本地网络」里才会有 SakuraDeBug 的开关。
            log("检查本地网络权限…（即将弹出授权弹窗，请务必选择「允许」）")
            let probe = LocalNetworkProbe()
            let authorized = await probe.request(timeout: 10)
            guard authorized else {
                isRunning = false
                phase = .failed("本地网络权限未开启。请重新点击开始（让权限弹窗再次弹出）并选择「允许」；若弹窗不出现，请到「设置 › 隐私与安全性 › 本地网络」确认 SakuraDeBug 是否在列表中。")
                log("❌ 本地网络权限探测失败：NetService 无法广播")
                return
            }
            log("✅ 本地网络权限正常，启动配对主机并广播…")
            runHost()
        }
    }

    func reset() {
        guard !isRunning else { return }
        stopAdvertising()
        pendingPublish = nil
        publishAttempt = 0
        apiFailureCount = 0
        phase = .idle
        deviceName = ""
        deviceUDID = ""
    }

    // MARK: - 配对主机（阻塞，后台线程）

    private func runHost() {
        // 确保配对文件输出目录存在（Application Support/Pairing）
        _ = PairingFileStore.prepareURL()
        let outPath = PairingFileStore.url.path
        log("配对文件将写入：\(outPath)")

        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = StikPairResult()
            let rc = self.bindAddress.withCString { bindC in
                self.hostName.withCString { nameC in
                    self.hostModel.withCString { modelC in
                        outPath.withCString { outC in
                            stikpair_run_host(
                                bindC, 0, nameC, modelC, outC,
                                SelfPairingController.readyCallback,
                                SelfPairingController.pinCallback,
                                ctx, &result)
                        }
                    }
                }
            }

            let success = rc == 0
            let deviceName = success ? SelfPairingController.cString(result.device_name) : ""
            let deviceUDID = success ? SelfPairingController.cString(result.device_udid) : ""
            let errorMsg = SelfPairingController.cString(result.error)
            stikpair_result_free(&result)
            if let ctx = ctx { Unmanaged<SelfPairingController>.fromOpaque(ctx).release() }

            DispatchQueue.main.async {
                self.stopAdvertising()
                self.isRunning = false
                if success {
                    // 同步一次存储（迁移 + 0o600 权限保护）
                    _ = PairingFileStore.prepareURL()
                    self.deviceName = deviceName
                    self.deviceUDID = deviceUDID
                    self.phase = .success
                    self.log("🎉 配对成功！设备：\(deviceName.isEmpty ? "未知" : deviceName)（\(deviceUDID)），配对文件已生成")
                } else {
                    let msg = errorMsg.isEmpty ? "配对失败（code \(rc)）" : errorMsg
                    self.phase = .failed(msg)
                    self.log("❌ \(msg)")
                }
            }
        }
    }

    // MARK: - 广播 / PIN

    private func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        publishAttempt = 0
        apiFailureCount = 0
        pendingPublish = PendingPublish(serviceID: serviceID, port: port, txt: txt)
        publishNow()
    }

    /// 执行一次 NetService 发布。重试时服务名追加序号，避免 mDNS 名字冲突（-72001）。
    private func publishNow() {
        guard let pending = pendingPublish else { return }
        let name: String
        if publishAttempt == 0 {
            name = pending.serviceID
        } else {
            name = "\(pending.serviceID)-\(publishAttempt + 1)"
        }
        let service = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp",
            name: name,
            port: pending.port)
        service.setTXTRecord(NetService.data(fromTXTRecord: pending.txt))
        service.delegate = netServiceDelegate
        service.publish()
        netService = service
        log("📡 正在广播 \(name)（类型 \(service.type)，域 \(service.domain)，端口 \(pending.port)，第 \(publishAttempt + 1)/\(maxPublishAttempts) 次尝试）…")
    }

    private func stopAdvertising() {
        // 先摘掉 delegate 再 stop：避免我们主动停止时误触发 didNotPublish（-72005 已取消）
        netService?.delegate = nil
        netService?.stop()
        netService = nil
    }

    /// 广播发布失败：未达上限则短暂等待后重试；达上限才判失败。
    private func handlePublishFailure(code: Int) {
        guard isRunning else { return }

        // -72000（未知错误）连续出现 = 网络 AP 隔离的典型特征：
        // iOS 本地注册成功（didPublish）后立即被网络层撤销（didNotPublish）。
        // 酒店 / 机场 / 企业 WiFi 几乎都开启了客户端隔离，mDNS 广播包被路由器丢弃。
        if code == -72000 {
            apiFailureCount += 1
        }

        guard publishAttempt < maxPublishAttempts - 1 else {
            isRunning = false
            pendingPublish = nil
            let msg: String
            if apiFailureCount >= 2 {
                // 连续 2+ 次 -72000 → 几乎可以确定是 AP 隔离
                msg = """
                    Bonjour 广播被网络拦截（连续 \(apiFailureCount) 次 -72000）。

                    ⚠️ 当前 WiFi 可能开启了 AP 隔离（酒店 / 机场 / 企业网常见），设备间无法互相发现。

                    解决方案（任选其一）：
                    ① 换一个没有 AP 隔离的 WiFi（家用宽带、手机热点）
                    ② 用另一台手机开热点，本机连热点后再试
                    ③ 如果有 Mac：Mac 开热点（系统设置 → 通用 → 共享 → 互联网共享），本机连 Mac 热点
                    ④ 用 USB 配对（不需要网络，最可靠）
                    """
            } else if code == -72008 {
                msg = "本地网络权限被拒绝。请到「设置 › 隐私与安全性 › 本地网络」打开 SakuraDeBug 的开关后重试。"
            } else {
                msg = "Bonjour 广播失败（错误码 \(code)），配对主机不可被发现。请查看日志。"
            }
            phase = .failed(msg)
            return
        }
        publishAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.pendingPublish != nil else { return }
                self.log("🔄 广播失败，即将自动重试（\(self.publishAttempt + 1)/\(self.maxPublishAttempts)）…")
                self.publishNow()
            }
        }
    }

    private func presentPin(_ pin: String) {
        phase = .showPin(pin)
        log("🔢 请到「设置 › 隐私与安全 › 开发者模式」选择 SakuraDeBug 并输入配对码：\(pin)")
    }

    private func log(_ line: String) {
        onLog?(line)
    }

    // MARK: - C 回调

    nonisolated private static let readyCallback: StikPairReadyCb = { ctx, serviceID, port, keys, vals, count in
        guard let ctx, let serviceID else { return }
        let controller = Unmanaged<SelfPairingController>.fromOpaque(ctx).takeUnretainedValue()
        let id = String(cString: serviceID)

        var txt: [String: Data] = [:]
        if let keys, let vals {
            for i in 0..<Int(count) {
                guard let k = keys[i], let v = vals[i] else { continue }
                txt[String(cString: k)] = Data(String(cString: v).utf8)
            }
        }
        let txtPreview = txt.map { "\($0.key)=\(String(data: $0.value, encoding: .utf8) ?? "?")" }
            .sorted().joined(separator: ", ")

        DispatchQueue.main.async {
            controller.log("📡 配对主机就绪：service=\(id)，端口=\(port)，TXT={\(txtPreview)}")
            if port <= 0 || port > 65535 {
                controller.log("⚠️ C 库返回非法端口 \(port)，Bonjour 广播可能失败（参数错误 -72004）")
            }
            controller.log("若「开发者模式」列表里没有 SakuraDeBug：请确认系统为 iOS 27+，且已允许本地网络权限")
            controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
        }
    }

    nonisolated private static let pinCallback: StikPairPinCb = { pin, ctx in
        guard let ctx, let pin else { return }
        let controller = Unmanaged<SelfPairingController>.fromOpaque(ctx).takeUnretainedValue()
        let pinString = String(cString: pin)
        DispatchQueue.main.async {
            controller.presentPin(pinString)
        }
    }

    nonisolated private static func cString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }
}

// MARK: - 本地网络权限探测
//
// 关键：必须用 NetService 真实发布服务来探测（与最终广播同一套 API）。
// 不要用 NWListener + includePeerToPeer —— P2P 通道不需要本地网络权限，
// 探测会"假成功"且不触发系统弹窗，导致「设置 › 本地网络」里根本不出现
// SakuraDeBug 的开关，后续真正的 mDNS 广播照样失败。

@MainActor
private final class LocalNetworkProbe: NSObject, NetServiceDelegate {
    private var netService: NetService?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// 探测服务类型（已加入 Info.plist 的 NSBonjourServices）
    private let probeType = "_sakuradebug-probe._tcp"

    func request(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont

            // 真实发布一次 Bonjour 服务：未授权时系统弹窗必现，
            // 授权结果会直接反映在 didPublish / didNotPublish 回调里。
            // port 传 0 由系统分配，仅作探测用途，探测完立即 stop。
            let service = NetService(
                domain: "local.",
                type: probeType,
                name: "SakuraDebug-Probe",
                port: 0)
            service.delegate = self
            service.publish()
            self.netService = service

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        // 注册成功 = 本地网络权限已授予（或已弹窗且允许）
        DispatchQueue.main.async { [weak self] in self?.finish(true) }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        // 发布失败 = 权限未授予（-72008）或服务名冲突等
        DispatchQueue.main.async { [weak self] in self?.finish(false) }
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        netService?.stop()
        netService = nil
    }
}

// MARK: - NetService 发布状态监听（广播失败不再静默）

private final class NetServiceDelegateObject: NSObject, NetServiceDelegate {
    var onLog: ((String) -> Void)?
    var onPublishFailed: ((String, Int) -> Void)?

    func netServiceDidPublish(_ sender: NetService) {
        onLog?("✅ Bonjour 广播成功：\(sender.name)（类型 \(sender.type)，域 \(sender.domain)，端口 \(sender.port)）")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        // 完整错误字典（含 NSLocalizedDescription 等），避免 -72000 撞码 Apple GSA 认证错误
        let details = errorDict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        let code = errorDict[NetService.errorCode]?.intValue
        let codeDesc: String
        switch code {
        case -72001: codeDesc = "服务名冲突"
        case -72002: codeDesc = "未找到"
        case -72004: codeDesc = "参数错误"
        case -72005: codeDesc = "已取消"
        case -72006: codeDesc = "无效"
        case -72007: codeDesc = "超时"
        case -72008: codeDesc = "缺少必要配置（本地网络权限被拒时常见）"
        case let c?: codeDesc = "错误码 \(c)"
        case nil: codeDesc = "未知错误"
        }
        let line = "❌ Bonjour 发布失败：\(codeDesc)（errorDict=[\(details)]）"
        onPublishFailed?(line, code ?? 0)
    }
}
