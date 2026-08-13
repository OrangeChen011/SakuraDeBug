//
//  JITEnabler.swift
//  SakuraDeBug
//
//  精简移植自 StikDebug/StikJIT 的 JITEnableContext.swift 与 IdeviceFFIBridge.swift。
//  核心链路：
//    导入配对文件 → LocalDevVPN 回环隧道(10.7.0.1:49152) → tunnel_create_rppairing
//    → remote_server_connect_rsd + debug_proxy_connect_rsd
//    → process_control_launch_app 启动目标 App（须带 get-task-allow）
//    → debugserver 发送 vAttach;<pidhex> 附加 → 发送 D detach（保留 CS_DEBUGGED 标志）
//

import Foundation
import Darwin
import idevice

typealias JITLogFunc = (String) -> Void

/// 开启 JIT 的完整执行器（单例）。
final class JITEnabler {
    static let shared = JITEnabler()

    // MARK: - 内部句柄

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?

        mutating func free() {
            if let handshake {
                rsd_handshake_free(handshake)
                self.handshake = nil
            }
            if let adapter {
                adapter_free(adapter)
                self.adapter = nil
            }
        }
    }

    private struct DebugSession {
        var remoteServer: OpaquePointer?
        var debugProxy: OpaquePointer?

        mutating func free() {
            if let debugProxy {
                debug_proxy_free(debugProxy)
                self.debugProxy = nil
            }
            if let remoteServer {
                remote_server_free(remoteServer)
                self.remoteServer = nil
            }
        }
    }

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    private let tunnelLock = NSLock()
    private var tunnelConnecting = false
    private var tunnelSemaphore: DispatchSemaphore?
    private var lastTunnelError: NSError?

    var adapterHandle: OpaquePointer? { adapter }
    var handshakeHandle: OpaquePointer? { handshake }

    /// 当前是否有可用的隧道。
    var isTunnelReady: Bool {
        adapter != nil && handshake != nil
    }

    private init() {
        // 初始化 idevice 日志（写入应用沙盒）
        let logURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idevice_log.txt")
        var path = Array(logURL.path.utf8CString)
        path.withUnsafeMutableBufferPointer { buffer in
            _ = idevice_init_logger(Info, Debug, buffer.baseAddress)
        }
    }

    deinit {
        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }
    }

    // MARK: - 错误与日志

    private func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(
            domain: "SakuraDeBug",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func nsString(from cString: UnsafePointer<CChar>?, fallback: String) -> String {
        guard let cString, let string = String(validatingUTF8: cString) else {
            return fallback
        }
        return string
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else {
            return makeError(fallback)
        }
        let message = nsString(from: ffiError.pointee.message, fallback: fallback)
        let error = makeError(message, code: Int(ffiError.pointee.code))
        idevice_error_free(ffiError)
        return error
    }

    private func emitLog(_ message: String, logger: JITLogFunc?) {
        logger?(message)
    }

    // MARK: - 配对文件

    private func getPairingFile() throws -> OpaquePointer {
        let pairingFileURL = PairingFileStore.prepareURL()

        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw makeError("配对文件不存在，请先导入 .mobiledevicepairing 配对文件。", code: -17)
        }

        var pairingFile: OpaquePointer?
        let ffiError = pairingFileURL.path.withCString { path in
            rp_pairing_file_read(path, &pairingFile)
        }

        if let ffiError {
            throw error(from: ffiError, fallback: "读取配对文件失败。")
        }

        guard let pairingFile else {
            throw makeError("读取配对文件失败。", code: -17)
        }

        return pairingFile
    }

    // MARK: - 隧道

    private func createTunnel(hostname: String) throws -> TunnelHandles {
        let pairingFile = try getPairingFile()
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = DeviceConnectionContext.targetIPAddress
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("无法解析目标 IP 地址：\(deviceIP)", code: -18)
        }

        var tunnel = TunnelHandles()
        let ffiError = hostname.withCString { hostname in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &tunnel.adapter,
                        &tunnel.handshake
                    )
                }
            }
        }

        if let ffiError {
            throw error(from: ffiError, fallback: "创建隧道失败")
        }

        guard tunnel.adapter != nil, tunnel.handshake != nil else {
            var incompleteTunnel = tunnel
            incompleteTunnel.free()
            throw makeError("隧道创建成功但没有有效的句柄")
        }

        return tunnel
    }

    func startTunnel(logger: JITLogFunc? = nil) throws {
        tunnelLock.lock()
        if tunnelConnecting {
            let waitSemaphore = tunnelSemaphore
            tunnelLock.unlock()

            if let waitSemaphore {
                waitSemaphore.wait()
                waitSemaphore.signal()
            }

            if let lastTunnelError {
                throw lastTunnelError
            }
            return
        }

        tunnelConnecting = true
        let completionSemaphore = DispatchSemaphore(value: 0)
        tunnelSemaphore = completionSemaphore
        tunnelLock.unlock()

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        var finalError: NSError?

        defer {
            tunnelLock.lock()
            tunnelConnecting = false
            tunnelSemaphore = nil
            lastTunnelError = finalError
            tunnelLock.unlock()
            completionSemaphore.signal()
        }

        do {
            let newTunnel = try createTunnel(hostname: "SakuraDeBug")
            newAdapter = newTunnel.adapter
            newHandshake = newTunnel.handshake
            emitLog("✅ 回环隧道已建立（\(DeviceConnectionContext.targetIPAddress):49152）", logger: logger)
        } catch let tunnelError as NSError {
            finalError = tunnelError
            throw tunnelError
        }

        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }

        adapter = newAdapter
        handshake = newHandshake
    }

    func ensureTunnel(logger: JITLogFunc? = nil) throws {
        if adapter == nil || handshake == nil {
            try startTunnel(logger: logger)
        }
    }

    func stopTunnel() {
        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }
        adapter = nil
        handshake = nil
    }

    private func withFreshDebugTunnel<T>(
        hostname: String,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        var tunnel = try createTunnel(hostname: hostname)
        defer { tunnel.free() }

        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未连接")
        }

        return try body(adapter, handshake)
    }

    // MARK: - 心跳保活

    private final class DebugHeartbeatKeepAlive {
        private static let defaultInterval: UInt64 = 2
        private static let maxInterval: UInt64 = 3

        private let queue = DispatchQueue(label: "com.jitopen.debug-heartbeat", qos: .utility)
        private let stateLock = NSLock()
        private let startupSemaphore = DispatchSemaphore(value: 0)
        private let stoppedSemaphore = DispatchSemaphore(value: 0)
        private let logger: JITLogFunc?
        private let makeClient: () throws -> (client: OpaquePointer, tunnel: TunnelHandles)
        private let errorBuilder: (UnsafeMutablePointer<IdeviceFfiError>?, String) -> NSError
        private var startupError: NSError?
        private var client: OpaquePointer?
        private var tunnel: TunnelHandles?
        private var stopRequested = false

        init(
            logger: JITLogFunc?,
            makeClient: @escaping () throws -> (client: OpaquePointer, tunnel: TunnelHandles),
            errorBuilder: @escaping (UnsafeMutablePointer<IdeviceFfiError>?, String) -> NSError
        ) {
            self.logger = logger
            self.makeClient = makeClient
            self.errorBuilder = errorBuilder
        }

        func start() throws {
            startupError = nil
            queue.async { [weak self] in
                self?.run()
            }
            startupSemaphore.wait()
            if let startupError {
                throw startupError
            }
        }

        func stop() {
            stateLock.lock()
            stopRequested = true
            stateLock.unlock()
            _ = stoppedSemaphore.wait(timeout: .now() + .seconds(Int(Self.maxInterval + 1)))
        }

        private func shouldStop() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stopRequested
        }

        private func run() {
            do {
                let resources = try makeClient()
                client = resources.client
                tunnel = resources.tunnel
                startupError = nil
            } catch let error as NSError {
                startupError = error
                startupSemaphore.signal()
                stoppedSemaphore.signal()
                return
            }

            defer {
                if let client {
                    heartbeat_client_free(client)
                    self.client = nil
                }
                if var tunnel = tunnel {
                    tunnel.free()
                    self.tunnel = nil
                }
                stoppedSemaphore.signal()
            }

            startupSemaphore.signal()

            var interval = Self.defaultInterval

            while !shouldStop(), let client {
                var suggestedInterval: UInt64 = 0
                let ffiError = heartbeat_get_marco(client, interval, &suggestedInterval)

                if shouldStop() {
                    break
                }

                if let ffiError {
                    let heartbeatError = errorBuilder(ffiError, "调试心跳失败")
                    let description = heartbeatError.localizedDescription

                    if description.contains("HeartbeatTimeout") {
                        interval = Self.defaultInterval
                        continue
                    }

                    if description.contains("HeartbeatSleepyTime") {
                        logger?("调试心跳停止：设备进入休眠")
                        break
                    }

                    logger?("调试心跳警告：\(description)")
                    interval = Self.defaultInterval
                    continue
                }

                interval = min(max(suggestedInterval, 1), Self.maxInterval)

                if let ffiError = heartbeat_send_polo(client) {
                    let heartbeatError = errorBuilder(ffiError, "心跳应答失败")
                    logger?("调试心跳警告：\(heartbeatError.localizedDescription)")
                    interval = Self.defaultInterval
                }
            }
        }
    }

    private func connectHeartbeatKeepAlive(logger: JITLogFunc?) throws -> DebugHeartbeatKeepAlive {
        DebugHeartbeatKeepAlive(
            logger: logger,
            makeClient: { [weak self] in
                guard let self else {
                    throw NSError(
                        domain: "SakuraDeBug",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "调试心跳上下文不可用"]
                    )
                }

                var tunnel = try self.createTunnel(hostname: "SakuraDeBugHeartbeat")
                guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                    tunnel.free()
                    throw self.makeError("隧道未连接")
                }

                var heartbeatClient: OpaquePointer?
                if let ffiError = heartbeat_connect_rsd(adapter, handshake, &heartbeatClient) {
                    tunnel.free()
                    throw self.error(from: ffiError, fallback: "连接调试心跳失败")
                }

                guard let heartbeatClient else {
                    tunnel.free()
                    throw self.makeError("心跳客户端未创建")
                }

                return (client: heartbeatClient, tunnel: tunnel)
            },
            errorBuilder: { [weak self] ffiError, fallback in
                self?.error(from: ffiError, fallback: fallback) ?? NSError(
                    domain: "SakuraDeBug",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: fallback]
                )
            }
        )
    }

    // MARK: - 调试会话

    private func connectDebugSession(adapter: OpaquePointer, handshake: OpaquePointer) throws -> DebugSession {
        var session = DebugSession()

        if let ffiError = remote_server_connect_rsd(adapter, handshake, &session.remoteServer) {
            throw error(from: ffiError, fallback: "连接远程服务失败")
        }

        if let ffiError = debug_proxy_connect_rsd(adapter, handshake, &session.debugProxy) {
            session.free()
            throw error(from: ffiError, fallback: "连接调试代理失败")
        }

        return session
    }

    private func withConnectedDebugSession<T>(
        logger: JITLogFunc?,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        emitLog("正在建立调试隧道…", logger: logger)
        return try withFreshDebugTunnel(hostname: "SakuraDeBugDebug") { adapter, handshake in
            var session = try connectDebugSession(adapter: adapter, handshake: handshake)
            defer { session.free() }

            guard let remoteServer = session.remoteServer,
                  let debugProxy = session.debugProxy else {
                throw makeError("调试会话未创建")
            }

            return try body(remoteServer, debugProxy)
        }
    }

    private func withConnectedRemoteServer<T>(
        logger: JITLogFunc?,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try ensureTunnel(logger: logger)
        guard let adapter, let handshake else {
            throw makeError("隧道未连接")
        }

        var remoteServer: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            throw error(from: ffiError, fallback: "连接远程服务失败")
        }

        guard let remoteServer else {
            throw makeError("远程服务句柄未创建")
        }

        defer { remote_server_free(remoteServer) }
        return try body(remoteServer)
    }

    private func withProcessControl<T>(
        remoteServer: OpaquePointer,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var processControl: OpaquePointer?
        if let ffiError = process_control_new(remoteServer, &processControl) {
            throw error(from: ffiError, fallback: "打开进程控制失败")
        }

        guard let processControl else {
            throw makeError("进程控制句柄未创建")
        }

        defer { process_control_free(processControl) }
        return try body(processControl)
    }

    // MARK: - debugserver 命令

    private func sendDebugCommand(_ command: String, debugProxy: OpaquePointer) throws -> String? {
        guard let commandHandle = debugserver_command_new(command, nil, 0) else {
            throw makeError("创建 debugserver 命令失败：\(command)")
        }

        var response: UnsafeMutablePointer<CChar>?
        let ffiError = debug_proxy_send_command(debugProxy, commandHandle, &response)
        debugserver_command_free(commandHandle)

        if let ffiError {
            if let response {
                idevice_string_free(response)
            }
            throw error(from: ffiError, fallback: "debugserver 命令失败：\(command)")
        }

        defer {
            if let response {
                idevice_string_free(response)
            }
        }

        guard let response else { return nil }
        return String(cString: response)
    }

    private func runDebugServerCommand(
        pid: Int32,
        debugProxy: OpaquePointer,
        remoteServer: OpaquePointer,
        logger: JITLogFunc?,
        callback: ((Int32, OpaquePointer, OpaquePointer, DispatchSemaphore) -> Void)?
    ) {
        debug_proxy_send_ack(debugProxy)
        debug_proxy_send_ack(debugProxy)

        do {
            let response = try sendDebugCommand("QStartNoAckMode", debugProxy: debugProxy) ?? "<nil>"
            emitLog("QStartNoAckMode → \(response)", logger: logger)
        } catch {
            emitLog(error.localizedDescription, logger: logger)
        }

        debug_proxy_set_ack_mode(debugProxy, 0)

        if let callback {
            let keepAlive: DebugHeartbeatKeepAlive?
            do {
                let heartbeat = try connectHeartbeatKeepAlive(logger: logger)
                try heartbeat.start()
                keepAlive = heartbeat
                emitLog("调试心跳保活已启动", logger: logger)
            } catch {
                keepAlive = nil
                emitLog("警告：调试心跳保活启动失败：\(error.localizedDescription)", logger: logger)
            }
            defer {
                keepAlive?.stop()
                if keepAlive != nil {
                    emitLog("调试心跳保活已停止", logger: logger)
                }
            }

            let semaphore = DispatchSemaphore(value: 0)
            callback(pid, debugProxy, remoteServer, semaphore)
            semaphore.wait()

            var breakByte: UInt8 = 0x03
            if let ffiError = debug_proxy_send_raw(debugProxy, &breakByte, 1) {
                emitLog(error(from: ffiError, fallback: "中断目标失败").localizedDescription, logger: logger)
            }
            usleep(500)
        } else {
            let attachCommand = "vAttach;\(String(UInt32(pid), radix: 16))"
            do {
                let response = try sendDebugCommand(attachCommand, debugProxy: debugProxy) ?? "<nil>"
                emitLog("附加目标 (vAttach;\(String(UInt32(pid), radix: 16))) → \(response)", logger: logger)
            } catch {
                emitLog(error.localizedDescription, logger: logger)
            }
        }

        do {
            let response = try sendDebugCommand("D", debugProxy: debugProxy)
            if let response {
                emitLog("分离调试器 (D) → \(response)", logger: logger)
            }
        } catch {
            emitLog(error.localizedDescription, logger: logger)
        }
    }

    // MARK: - 对外能力

    /// 启动目标 App 并附加调试器开启 JIT。
    @discardableResult
    func debugApp(withBundleID bundleID: String, logger: JITLogFunc? = nil) -> Bool {
        emitLog("开始为 \(bundleID) 开启 JIT…", logger: logger)
        do {
            let _: Void = try withConnectedDebugSession(logger: logger) { remoteServer, debugProxy in
                let pid = try withProcessControl(remoteServer: remoteServer) { processControl in
                    var pid: UInt64 = 0
                    let ffiError = bundleID.withCString { bundleID in
                        process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, true, false, &pid)
                    }

                    if let ffiError {
                        throw error(from: ffiError, fallback: "启动 App 失败")
                    }

                    return Int32(pid)
                }

                emitLog("目标 App 已启动（PID \(pid)），正在附加调试器…", logger: logger)
                runDebugServerCommand(
                    pid: pid,
                    debugProxy: debugProxy,
                    remoteServer: remoteServer,
                    logger: logger,
                    callback: nil
                )
            }

            emitLog("✅ JIT 开启流程完成", logger: logger)
            return true
        } catch {
            emitLog("❌ \(error.localizedDescription)", logger: logger)
            return false
        }
    }

    /// 仅启动 App，不附加调试器（调试/回退用途）。
    @discardableResult
    func launchAppWithoutDebug(_ bundleID: String, logger: JITLogFunc? = nil) -> Bool {
        do {
            let pid = try withConnectedRemoteServer(logger: logger) { remoteServer in
                try withProcessControl(remoteServer: remoteServer) { processControl in
                    var pid: UInt64 = 0
                    let ffiError = bundleID.withCString { bundleID in
                        process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, false, true, &pid)
                    }

                    if let ffiError {
                        throw error(from: ffiError, fallback: "启动 App 失败")
                    }

                    return pid
                }
            }

            emitLog("已启动 App（PID \(pid)，未附加调试器）", logger: logger)
            return true
        } catch {
            emitLog(error.localizedDescription, logger: logger)
            return false
        }
    }

    // MARK: - App 列表

    /// 列出已安装 App（bundleID → 名称）。
    /// - Parameter requireGetTaskAllow: 仅保留带 get-task-allow entitlement 的 App（可开 JIT）。
    func getAppList(requireGetTaskAllow: Bool, logger: JITLogFunc? = nil) throws -> [String: String] {
        try ensureTunnel(logger: logger)
        guard let adapter, let handshake else {
            throw makeError("隧道未连接")
        }

        return try plistDictionaries(adapter: adapter, handshake: handshake) { dictionary in
            if requireGetTaskAllow && !Self.hasGetTaskAllow(dictionary) {
                return false
            }
            return true
        }
    }

    /// 所有已安装 App。
    func getAllApps(logger: JITLogFunc? = nil) throws -> [String: String] {
        try getAppList(requireGetTaskAllow: false, logger: logger)
    }

    private func plistDictionaries(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        filter: (([String: Any]) -> Bool)? = nil
    ) throws -> [String: String] {
        var installationProxy: OpaquePointer?
        if let ffiError = installation_proxy_connect_rsd(adapter, handshake, &installationProxy) {
            throw error(from: ffiError, fallback: "连接安装代理失败")
        }
        guard let installationProxy else {
            throw makeError("安装代理客户端未创建")
        }
        defer { installation_proxy_client_free(installationProxy) }

        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(installationProxy, nil, nil, 0, &rawApps, &count) {
            throw error(from: ffiError, fallback: "获取已安装 App 列表失败")
        }

        guard let rawApps, count > 0 else { return [:] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(
                rawApps.assumingMemoryBound(to: UInt8.self),
                UInt(count * MemoryLayout<plist_t?>.stride)
            )
        }

        var result: [String: String] = [:]
        result.reserveCapacity(count)

        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            let app = apps[index]

            guard plist_to_bin(app, &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist,
                  binaryLength > 0 else {
                continue
            }

            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any] else {
                continue
            }

            if let filter, !filter(dictionary) {
                continue
            }

            guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }

            result[bundleID] = Self.appName(from: dictionary)
        }

        return result
    }

    private static func appName(from dictionary: [String: Any]) -> String {
        if let displayName = dictionary["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = dictionary["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return "未知 App"
    }

    private static func hasGetTaskAllow(_ dictionary: [String: Any]) -> Bool {
        guard let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return false
        }

        if let flag = entitlements["get-task-allow"] as? Bool {
            return flag
        }

        if let flag = entitlements["get-task-allow"] as? NSNumber {
            return flag.boolValue
        }

        return false
    }
}
