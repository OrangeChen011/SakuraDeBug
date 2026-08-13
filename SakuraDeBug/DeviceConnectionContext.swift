//
//  DeviceConnectionContext.swift
//  SakuraDeBug
//
//  连接上下文：LocalDevVPN 回环隧道目标地址。
//  移植自 StikDebug/StikJIT。
//

import Foundation

enum DeviceConnectionContext {
    static let defaultTargetIPAddress = "10.7.0.1"
    static let targetPort = 49152

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: "targetDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }
}
