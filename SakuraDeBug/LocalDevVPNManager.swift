//
//  LocalDevVPNManager.swift
//  SakuraDeBug
//
//  内嵌 LocalDevVPN 的主 App 侧管理器：通过 NETunnelProviderManager 安装、
//  启动、停止回环 VPN 配置（PacketTunnelProvider 扩展负责实际转发）。
//
//  首次安装会触发系统的「添加 VPN 配置」授权弹窗，用户同意后配置持久化；
//  之后可随时启停，无需再次确认（除非在系统设置里删除了配置）。
//
//  ⚠️ 使用前提（与 LocalDevVPN App Store 版一致）：
//     开发者账号需在 Xcode 里开启「Network Extensions」capability。
//

import Foundation
import NetworkExtension

@MainActor
final class LocalDevVPNManager: ObservableObject {

    static let shared = LocalDevVPNManager()

    /// VPN 状态
    enum Status: Equatable {
        case notInstalled    // 尚未安装 VPN 配置
        case installing      // 等待用户在系统弹窗中确认
        case installed       // 已安装但未连接
        case connecting
        case connected       // 回环隧道工作中（可开 JIT）
        case disconnecting
        case error(String)
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var isEnabled = false

    /// 日志回调（绑定到 ContentView 日志区）
    var onLog: ((String) -> Void)?

    /// App Group 未使用（配置里不传 providerBundleIdentifier 之外的数据）
    private let localizedDescription = "SakuraDeBug 内嵌 LocalDevVPN"

    private init() {
        refreshStatus()
        // 监听系统 VPN 状态变化（用户可能从设置里手动开关）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnConfigurationChanged),
            name: .NEVPNConfigurationChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .NEVPNConfigurationChange, object: nil)
    }

    @objc private func vpnConfigurationChanged() {
        Task { @MainActor in
            self.refreshStatus()
        }
    }

    // MARK: - 状态刷新

    func refreshStatus() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.status = .error("读取 VPN 配置失败：\(error.localizedDescription)")
                    self.log("❌ 读取 VPN 配置失败：\(error.localizedDescription)")
                    return
                }
                guard let manager = Self.ours(from: managers) else {
                    self.status = .notInstalled
                    self.isEnabled = false
                    return
                }
                self.isEnabled = manager.isEnabled
                switch manager.connection.status {
                case .connected:
                    self.status = .connected
                case .connecting, .reasserting:
                    self.status = .connecting
                case .disconnecting:
                    self.status = .disconnecting
                default:
                    self.status = manager.isEnabled ? .installed : .notInstalled
                }
            }
        }
    }

    /// 从系统 VPN 配置列表里找出属于本 App 的那一条
    private static func ours(from managers: [NETunnelProviderManager]?) -> NETunnelProviderManager? {
        managers?.first { $0.localizedDescription == "SakuraDeBug 内嵌 LocalDevVPN" }
            ?? managers?.first { $0.localizedDescription == "SakuraDeBug" }
    }

    // MARK: - 安装 / 启动

    /// 一键开启：未安装则先安装（触发系统授权弹窗），再连接。
    func enable() {
        status = .installing
        log("正在准备内嵌 LocalDevVPN…")

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }

                let manager: NETunnelProviderManager
                if let existing = Self.ours(from: managers) {
                    manager = existing
                } else if let error {
                    self.status = .error("加载 VPN 配置失败：\(error.localizedDescription)")
                    self.log("❌ 加载 VPN 配置失败：\(error.localizedDescription)")
                    return
                } else {
                    manager = NETunnelProviderManager()
                }

                self.configure(manager)
                manager.saveToPreferences { saveError in
                    Task { @MainActor in
                        if let saveError {
                            // 用户拒绝授权弹窗等
                            self.status = .error("保存 VPN 配置失败：\(saveError.localizedDescription)")
                            self.log("❌ 保存 VPN 配置失败：\(saveError.localizedDescription)（请在弹窗中选择「允许」）")
                            return
                        }
                        // save 成功后需要重新 load 才能拿到有效的 provider（系统限制）
                        manager.loadFromPreferences { _ in
                            Task { @MainActor in
                                self.connect(manager)
                            }
                        }
                    }
                }
            }
        }
    }

    private func configure(_ manager: NETunnelProviderManager) {
        // 指向我们内嵌的 PacketTunnelProvider 扩展
        let bundleID = (Bundle.main.bundleIdentifier ?? "o160320cjh-163.com.SakuraDeBug") + ".packettunnel"
        manager.localizedDescription = localizedDescription
        manager.protocolConfiguration = Self.makeProtocol(bundleID: bundleID)
        manager.isEnabled = true
        manager.onDemandRules = [] // 不做按需连接，完全手动控制
    }

    private static func makeProtocol(bundleID: String) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundleID
        proto.providerConfiguration = [:]
        proto.serverAddress = "127.0.0.1" // 仅展示用（设置里显示的"服务器"）
        return proto
    }

    private func connect(_ manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            status = .connecting
            log("🔌 回环隧道连接中…（劫持 10.7.0.1 → 127.0.0.1）")
            // 轮询状态直到 connected / failed
            pollStatus()
        } catch {
            status = .error("启动 VPN 失败：\(error.localizedDescription)")
            log("❌ 启动 VPN 失败：\(error.localizedDescription)")
        }
    }

    private func pollStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            switch self.status {
            case .connecting:
                self.refreshStatus()
                // 5 秒后仍在连接中：刷新一次后继续等
                self.pollStatus()
            default:
                break
            }
        }
    }

    // MARK: - 关闭

    func disable() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let manager = Self.ours(from: managers) else { return }
                manager.connection.stopVPNTunnel()
                self.status = .installed
                self.isEnabled = manager.isEnabled
                self.log("回环隧道已关闭")
            }
        }
    }

    /// 彻底移除 VPN 配置（调试用途）
    func removeConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let manager = Self.ours(from: managers) else { return }
                manager.removeFromPreferences { _ in
                    Task { @MainActor in
                        self.status = .notInstalled
                        self.isEnabled = false
                        self.log("VPN 配置已移除")
                    }
                }
            }
        }
    }

    /// 当前是否可以用来开 JIT
    var isReady: Bool {
        status == .connected
    }

    private func log(_ line: String) {
        onLog?(line)
    }
}
