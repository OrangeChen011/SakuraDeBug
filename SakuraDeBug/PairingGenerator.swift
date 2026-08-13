//
//  PairingGenerator.swift
//  SakuraDeBug
//
//  USB 一键生成配对文件（参考 StikPair / jkcoxson idevice_pair 的思路）。
//  核心链路：
//    usbmuxd 枚举 USB 设备 → usbmuxd_provider_new 建立设备连接
//    → tunnel_pair_usb 走 CoreDeviceProxy USB 隧道 + RPPairing 协议完成配对
//    → rp_pairing_file_write 写入配对文件（与 JIT 隧道的 tunnel_create_rppairing 完全兼容）
//
//  相比"从别的电脑导出配对文件"，本功能让这台 Mac 直接与设备完成配对，
//  生成的配对文件开箱即用，无需额外工具。
//

import Foundation
import Darwin
import idevice

final class PairingGenerator {
    static let shared = PairingGenerator()

    private init() {}

    // MARK: - 错误

    private func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(
            domain: "SakuraDeBug",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else {
            return makeError(fallback)
        }
        let message = String(validatingUTF8: ffiError.pointee.message) ?? fallback
        let error = makeError(message, code: Int(ffiError.pointee.code))
        idevice_error_free(ffiError)
        return error
    }

    // MARK: - 生成配对文件

    /// 枚举当前 USB 设备（用于 UI 展示设备状态）。
    func listDevices() -> [String] {
        guard let conn = openUsbmuxd() else { return [] }
        defer { idevice_usbmuxd_connection_free(conn) }

        var devices: UnsafeMutablePointer<OpaquePointer?>?
        var count: Int32 = 0
        guard idevice_usbmuxd_get_devices(conn, &devices, &count) == nil, count > 0, let devices else {
            return []
        }
        defer { idevice_usbmuxd_device_list_free(devices, count) }

        var result: [String] = []
        for index in 0..<Int(count) {
            guard let device = devices[index] else { continue }
            let udid = String(validatingUTF8: idevice_usbmuxd_device_get_udid(device)) ?? "unknown"
            let deviceID = idevice_usbmuxd_device_get_device_id(device)
            result.append("\(udid)（mux ID \(deviceID)）")
        }
        return result
    }

    /// USB 一键生成配对文件，写入 PairingFileStore 的标准位置。
    func generatePairingFile(hostname: String = "SakuraDeBug", logger: JITLogFunc? = nil) throws {
        emit("🖥 正在扫描 USB 设备…", logger: logger)

        // 1. 连接 usbmuxd
        var conn: OpaquePointer?
        var ffiError = idevice_usbmuxd_new_default_connection(0, &conn)
        if let ffiError {
            throw error(from: ffiError, fallback: "无法连接 usbmuxd。请确认设备已通过 USB 连接。")
        }
        guard let conn else {
            throw makeError("usbmuxd 连接为空。")
        }
        defer { idevice_usbmuxd_connection_free(conn) }

        // 2. 枚举 USB 设备
        var devices: UnsafeMutablePointer<OpaquePointer?>?
        var count: Int32 = 0
        ffiError = idevice_usbmuxd_get_devices(conn, &devices, &count)
        if let ffiError {
            throw error(from: ffiError, fallback: "获取设备列表失败。")
        }
        guard count > 0, let devices else {
            throw makeError("未检测到 USB 设备。请用数据线连接 iPhone/iPad，解锁屏幕并开启开发者模式。")
        }
        defer { idevice_usbmuxd_device_list_free(devices, count) }

        // 3. 取第一个设备
        guard let device = devices[0] else {
            throw makeError("设备句柄为空。")
        }
        let udid = String(validatingUTF8: idevice_usbmuxd_device_get_udid(device)) ?? "unknown"
        let deviceID = idevice_usbmuxd_device_get_device_id(device)
        emit("📱 发现设备：\(udid)（mux ID \(deviceID)）", logger: logger)
        emit("🔑 正在通过 CoreDeviceProxy USB 隧道配对（请保持设备解锁）…", logger: logger)

        // 4. 创建设备 provider（addr 会被 usbmuxd_provider_new 消费，无需手动释放）
        var addr: OpaquePointer?
        ffiError = idevice_usbmuxd_default_addr_new(&addr)
        if let ffiError {
            throw error(from: ffiError, fallback: "创建 usbmuxd 地址失败。")
        }
        guard let addr else {
            throw makeError("usbmuxd 地址为空。")
        }

        var provider: OpaquePointer?
        ffiError = udid.withCString { udid in
            hostname.withCString { label in
                usbmuxd_provider_new(addr, 0, udid, deviceID, label, &provider)
            }
        }
        if let ffiError {
            throw error(from: ffiError, fallback: "连接设备失败。")
        }
        guard let provider else {
            throw makeError("设备连接为空。")
        }
        defer { idevice_provider_free(provider) }

        // 5. RPPairing 配对（iOS 上 pin_callback 传 nil，默认 "000000"）
        var pairingFile: OpaquePointer?
        ffiError = hostname.withCString { hostname in
            tunnel_pair_usb(provider, hostname, nil, nil, &pairingFile)
        }
        if let ffiError {
            throw error(from: ffiError, fallback: "配对失败。请确认设备已解锁、开启开发者模式，并允许本机连接。")
        }
        defer { rp_pairing_file_free(pairingFile) }
        guard let pairingFile else {
            throw makeError("配对结果为空。")
        }

        // 6. 写入配对文件并保护权限
        let destination = PairingFileStore.url
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = destination.path
        ffiError = path.withCString { path in
            rp_pairing_file_write(pairingFile, path)
        }
        if let ffiError {
            throw error(from: ffiError, fallback: "写入配对文件失败。")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        emit("✅ 配对成功，配对文件已生成：\(destination.lastPathComponent)", logger: logger)
        emit("💡 现在可以点击「刷新可开 JIT 的 App 列表」开始使用。", logger: logger)
    }

    // MARK: - 辅助

    private func openUsbmuxd() -> OpaquePointer? {
        var conn: OpaquePointer?
        guard idevice_usbmuxd_new_default_connection(0, &conn) == nil, let conn else {
            return nil
        }
        return conn
    }

    private func emit(_ message: String, logger: JITLogFunc?) {
        logger?(message)
    }
}
