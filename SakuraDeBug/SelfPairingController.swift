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
        netServiceDelegate.onPublishFailed = { [weak self] line in
            self?.log(line)
            if self?.isRunning == true {
                self?.isRunning = false
                self?.phase = .failed("Bonjour 广播失败，配对主机不可被发现。请查看日志。")
            }
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

    var isAdvertising: Bool { netService != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        phase = .waiting
        deviceName = ""
        deviceUDID = ""
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
        netService?.stop()
        netService = nil
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
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = netServiceDelegate
        service.publish()
        netService = service
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
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
    var onPublishFailed: ((String) -> Void)?

    func netServiceDidPublish(_ sender: NetService) {
        onLog?("✅ Bonjour 广播成功：\(sender.name)（端口 \(sender.port)）")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -72000
        let info: String
        switch code {
        case -72001: info = "服务名冲突"
        case -72002: info = "未找到"
        case -72004: info = "参数错误"
        case -72005: info = "已取消"
        case -72006: info = "无效"
        case -72007: info = "超时"
        case -72008: info = "缺少必要配置（本地网络权限被拒时常见）"
        default: info = "错误码 \(code)"
        }
        onPublishFailed?("❌ Bonjour 发布失败：\(info)")
    }
}
