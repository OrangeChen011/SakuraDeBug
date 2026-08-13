//
//  SelfPairingController.swift
//  SakuraDeBug
//
//  设备自配对：本机伪装成 PairableHost（Mac 主机），通过 NetService 广播
//  `_remotepairing-pairable-host._tcp.` 服务，用户到「设置 › 开发者模式」
//  里与本机配对并输入 PIN，配对文件直接生成到标准位置，全程不经过电脑。
//  移植自 StikDebug/StikPair 的 PairingController（裁剪掉 Apple TV / 后台任务 / keepalive）。
//

import Foundation
import StikPairFFI

@MainActor
final class SelfPairingController: ObservableObject {

    static let shared = SelfPairingController()

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

    private let bindAddress = "0.0.0.0"
    private let hostName = "SakuraDeBug"
    private let hostModel = "Mac17,7"

    private var netService: NetService?
    private(set) var isRunning = false

    var isAdvertising: Bool { netService != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        phase = .waiting
        deviceName = ""
        deviceUDID = ""

        // 确保配对文件输出目录存在（Application Support/Pairing）
        _ = PairingFileStore.prepareURL()
        let outPath = PairingFileStore.url.path

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
                } else {
                    self.phase = .failed(errorMsg.isEmpty ? "配对失败（code \(rc)）" : errorMsg)
                }
            }
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

    // MARK: - 广播 / PIN

    private func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    private func presentPin(_ pin: String) {
        phase = .showPin(pin)
    }

    // MARK: - C 回调

    private static let readyCallback: StikPairReadyCb = { ctx, serviceID, port, keys, vals, count in
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
            controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
        }
    }

    private static let pinCallback: StikPairPinCb = { pin, ctx in
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
