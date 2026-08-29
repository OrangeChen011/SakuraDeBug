//
//  SelfPairingController.swift
//  SakuraDeBug
//
//  设备自配对：本机伪装为 PairableHost（Mac 主机），通过 NetService 广播
//  `_remotepairing-pairable-host._tcp.` 服务，用户到「设置 › 开发者模式」
//  里与本机配对并输入 PIN，配对文件直接生成到标准位置，全程不经过电脑。
//  移植自 StikPair 的 PairingController（https://github.com/StikDebug/StikPair）。
//
//  注意：配对列表 UI 需要 iOS 27+（StikPair 同款依赖），iOS 26 及以下的
//  开发者模式页面没有 PairableHost 配对入口。
//

import Foundation
import Network
import StikPairFFI
import UIKit

@MainActor
final class SelfPairingController: ObservableObject {

    static let shared = SelfPairingController()
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.sakura.SakuraDeBug") + ".pairing"

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

    /// 日志历史（最近 500 条，供网页控制台读取）
    private(set) var logHistory: [String] = []

    private let bindAddress = "0.0.0.0"
    private let hostName = "SakuraDeBug"
    private let hostModel = "Mac17,7"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private(set) var isRunning = false

    /// beginBackgroundTask 标识符（用户切到「设置」配对时保持 App 存活）
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pairingStarted = false

    private init() {}

    // MARK: - 对外接口

    func start() {
        guard !isRunning else { return }
        phase = .waiting
        deviceName = ""
        deviceUDID = ""
        log("开始设备自配对（本机伪装为 Mac 配对主机，无需电脑）…")

        Task {
            log("检查本地网络权限…（即将弹出授权弹窗，请务必选择「允许」）")
            let authorized = await localNetwork.request(timeout: 60)
            guard authorized else {
                isRunning = false
                phase = .failed("本地网络权限未开启。请重新点击开始（让权限弹窗再次弹出）并选择「允许」；若弹窗不出现，请到「设置 › 隐私与安全性 › 本地网络」确认 SakuraDeBug 是否在列表中。")
                log("❌ 本地网络权限探测失败：NetService 无法广播")
                return
            }
            log("✅ 本地网络权限正常，启动配对主机并广播…")
            beginBackgroundTaskIfNeeded()
            runPairing()
        }
    }

    func reset() {
        guard !isRunning else { return }
        stopAdvertising()
        phase = .idle
        deviceName = ""
        deviceUDID = ""
    }

    // MARK: - 配对主机（阻塞，后台线程）

    private func runPairing() {
        guard !pairingStarted else { return }
        pairingStarted = true
        isRunning = true

        // 确保配对文件输出目录存在（Application Support/Pairing）
        _ = PairingFileStore.prepareURL()
        let outPath = PairingFileStore.url.path
        log("配对文件将写入：\(outPath)")

        let bind = bindAddress
        let name = hostName
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = StikPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
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
                self.pairingStarted = false
                self.endBackgroundTaskIfNeeded()
                if success {
                    _ = PairingFileStore.prepareURL()
                    self.deviceName = deviceName
                    self.deviceUDID = deviceUDID
                    self.phase = .success
                    self.log("配对成功！设备：\(deviceName.isEmpty ? "未知" : deviceName)（\(deviceUDID)），配对文件已生成")
                } else {
                    let msg = errorMsg.isEmpty ? "配对失败（code \(rc)）" : errorMsg
                    self.phase = .failed(msg)
                    self.log("❌ \(msg)")
                }
            }
        }
    }

    // MARK: - 后台保活（beginBackgroundTask）

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SakuraDeBugPairing") { [weak self] in
            guard let self else { return }
            self.backgroundTaskID = .invalid
            if self.isRunning {
                self.log("⏰ 后台运行时间到期，配对可能中断。请保持 App 在前台或重新点击开始配对。")
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - 广播 / PIN

    /// 发布 Bonjour 服务（与 StikPair 原版完全一致：不设 delegate、不重试）。
    /// Rust TCP 服务器已就绪，这里只做 mDNS 广播让 iOS「设置」能发现。
    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        log("📡 正在广播 \(serviceID)（端口 \(port)）…")
        log("若「开发者模式」列表里没有 SakuraDeBug：请确认系统为 iOS 27+，且已允许本地网络权限")
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
        logHistory.append(line)
        if logHistory.count > 500 {
            logHistory.removeFirst(logHistory.count - 500)
        }
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

        DispatchQueue.main.async {
            controller.log("📡 配对主机就绪：service=\(id)，端口=\(port)")
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
// 与 StikPair 原版完全一致：使用 NWBrowser + NWListener（includePeerToPeer = true）
// 来探测本地网络权限。includePeerToPeer 启用 AWDL 点对点，即使 WiFi 有 AP 隔离
// 也能工作。比 NetService 发布探测更准确——它真正测试网络能否发现服务，
// 而非仅仅检查系统是否允许发布。

@MainActor
private final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    private let probeType = "_sakuradebug-probe._tcp"

    func request(timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont

            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try? NWListener(using: params)
            listener?.service = NWListener.Service(name: "SakuraDebug-Probe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(false) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(false) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }
}
