//
//  PacketTunnelProvider.swift
//  SakuraDeBugPacketTunnel
//
//  内嵌 LocalDevVPN：NEPacketTunnelProvider 实现的回环隧道。
//  原理：创建 TUN 虚拟网卡（10.7.0.2/24），把发往 10.7.0.1 的 TCP 连接
//  在用户态代理到 127.0.0.1（本机 RemotePairing / lockdownd 服务监听处），
//  免去单独安装 App Store 版 LocalDevVPN。
//
//  数据通路：
//    App(idevice FFI) → connect 10.7.0.1:49152
//      → TUN 路由 → packetFlow.readPackets（本 Provider 收到 SYN）
//      → NWConnection(127.0.0.1:49152) 建立真实连接
//      → 双向转发（TUN 侧手工维护 TCP 状态机 + 校验和）
//

import NetworkExtension
import Network

final class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - 配置

    /// 需要劫持的目标地址（与 DeviceConnectionContext.defaultTargetIPAddress 保持一致）
    /// 解析后的形式：0x0A070001 = 10.7.0.1
    static let targetIPAddress: UInt32 = 0x0A070001
    /// TUN 本机地址
    private static let tunnelAddress = "10.7.0.2"
    private static let tunnelSubnet = "255.255.255.0"

    /// 活动的 TCP 连接表（key = 客户端源端口）
    private var tcpConnections: [UInt16: TCPProxyConnection] = [:]
    /// 串行队列：所有连接表/TUN 读写操作在此执行，避免数据竞争
    private let workQueue = DispatchQueue(label: "com.sakuradebug.packettunnel")

    private var isRunning = false

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4Settings = NEIPv4Settings(
            addresses: [Self.tunnelAddress],
            subnetMasks: [Self.tunnelSubnet]
        )
        // 只劫持 10.7.0.1/32 这一条路由，不影响正常上网
        ipv4Settings.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")
        ]
        settings.ipv4Settings = ipv4Settings
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                completionHandler(error)
                return
            }
            self?.isRunning = true
            self?.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        let connections = tcpConnections.values
        tcpConnections.removeAll()
        workQueue.async {
            for connection in connections {
                connection.abort()
            }
        }
        completionHandler()
    }

    // MARK: - 读包循环

    private func readPackets() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning else { return }
            self.workQueue.async {
                for packet in packets {
                    self.handlePacket(packet)
                }
            }
            self.readPackets()
        }
    }

    // MARK: - 包分发

    private func handlePacket(_ packet: Data) {
        guard let ip = IPv4Header.parse(packet) else { return }

        // 只处理发往 10.7.0.1 的 TCP 包
        guard ip.protocol == UInt8(IPPROTO_TCP),
              ip.destinationAddress == Self.targetIPAddress,
              packet.count >= IPv4Header.length + TCPHeader.minLength,
              let tcp = TCPHeader.parse(packet, at: IPv4Header.length)
        else {
            // UDP（如 DNS）等其他流量：构造 ICMP 不可达，避免请求挂死
            if ip.protocol == UInt8(IPPROTO_UDP) {
                sendICMPPortUnreachable(for: packet, ip: ip)
            }
            return
        }

        handleTCPPacket(tcp, ip: ip, packet: packet)
    }

    private func handleTCPPacket(_ tcp: TCPHeader, ip: IPv4Header, packet: Data) {
        let key = tcp.sourcePort

        if tcp.isSYN, !tcp.isACK {
            // 新连接
            guard tcpConnections[key] == nil else {
                // 重复 SYN：重发 SYN-ACK
                tcpConnections[key]?.resendSYNACK()
                return
            }
            let connection = TCPProxyConnection(
                provider: self,
                clientAddress: ip.sourceAddress,
                clientPort: tcp.sourcePort,
                targetPort: tcp.destinationPort,
                clientISN: tcp.sequenceNumber
            )
            tcpConnections[key] = connection
            connection.handleSYN(tcp: tcp, ip: ip)
            return
        }

        guard let connection = tcpConnections[key] else {
            // 未知连接的非 SYN 包：RST 掉
            if tcp.isRST { return }
            sendTCPRST(clientAddress: ip.sourceAddress,
                       clientPort: tcp.sourcePort,
                       serverPort: tcp.destinationPort,
                       seq: tcp.acknowledgmentNumber)
            return
        }

        let headerLength = IPv4Header.length + tcp.dataOffset * 4
        let payload = packet.count > headerLength ? packet.subdata(in: headerLength..<packet.count) : Data()
        connection.handlePacket(tcp: tcp, ip: ip, payload: payload)
    }

    // MARK: - 出包（写回 TUN）

    /// 由 TCPProxyConnection 调用，把构造好的 IP 包写回 TUN。
    func writePacket(_ packet: Data) {
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }

    /// 连接关闭后从表中移除
    func removeConnection(port: UInt16) {
        workQueue.async { [weak self] in
            self?.tcpConnections[port] = nil
        }
    }

    // MARK: - 错误响应包

    private func sendTCPRST(clientAddress: UInt32, clientPort: UInt16, serverPort: UInt16, seq: UInt32) {
        let rst = buildTCPPacket(
            sourceAddress: Self.targetIPAddress,
            destinationAddress: clientAddress,
            sourcePort: serverPort,
            destinationPort: clientPort,
            seq: seq,
            ack: 0,
            flags: TCPHeader.flagRST | TCPHeader.flagACK,
            payload: Data()
        )
        writePacket(rst)
    }

    private func sendICMPPortUnreachable(for originalPacket: Data, ip: IPv4Header) {
        // ICMP Type=3 Code=3（端口不可达）；载荷 = 原 IP 头 + 8 字节
        var icmp = Data()
        icmp.append(contentsOf: [3, 3, 0, 0]) // type, code, checksum(占位), unused
        icmp.append(originalPacket.prefix(IPv4Header.length))
        icmp.append(originalPacket.dropFirst(IPv4Header.length).prefix(8))

        // 校验和
        let checksum = Self.internetChecksum(icmp)
        icmp[2] = UInt8(checksum & 0xFF)
        icmp[3] = UInt8(checksum >> 8)

        let packet = Self.buildIPv4Packet(
            sourceAddress: Self.targetIPAddress,
            destinationAddress: ip.sourceAddress,
            protocolId: 1, // ICMP
            payload: icmp
        )
        writePacket(packet)
    }

    // MARK: - 包构造辅助

    /// 构造完整 IP+TCP 包（含伪首部校验和）
    func buildTCPPacket(sourceAddress: UInt32,
                        destinationAddress: UInt32,
                        sourcePort: UInt16,
                        destinationPort: UInt16,
                        seq: UInt32,
                        ack: UInt32,
                        flags: UInt8,
                        payload: Data,
                        window: UInt16 = 65535) -> Data {
        // 1. TCP 段（网络字节序，checksum 占位 0）
        var segment = Data(capacity: TCPHeader.minLength + payload.count)
        Self.appendUInt16(&segment, sourcePort)
        Self.appendUInt16(&segment, destinationPort)
        Self.appendUInt32(&segment, seq)
        Self.appendUInt32(&segment, ack)
        Self.appendUInt16(&segment, UInt16((5 << 12) | Int(flags))) // dataOffset=5, flags
        Self.appendUInt16(&segment, window)
        Self.appendUInt16(&segment, 0) // checksum 占位
        Self.appendUInt16(&segment, 0) // urgent pointer
        segment.append(payload)

        // 2. TCP 校验和 = 伪首部 + TCP 段
        var pseudo = Data()
        Self.appendUInt32(&pseudo, sourceAddress)
        Self.appendUInt32(&pseudo, destinationAddress)
        pseudo.append(0)
        pseudo.append(UInt8(IPPROTO_TCP))
        Self.appendUInt16(&pseudo, UInt16(segment.count))
        pseudo.append(segment)

        let checksum = Self.internetChecksum(pseudo)
        // 写入 checksum 字段（TCP 头内偏移 16-17）
        segment[16] = UInt8(checksum & 0xFF)
        segment[17] = UInt8(checksum >> 8)

        // 3. 套上 IP 头
        return Self.buildIPv4Packet(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            protocolId: UInt8(IPPROTO_TCP),
            payload: segment
        )
    }

    static func buildIPv4Packet(sourceAddress: UInt32,
                                destinationAddress: UInt32,
                                protocolId: UInt8,
                                payload: Data) -> Data {
        var packet = Data(capacity: IPv4Header.length + payload.count)
        packet.append(0x45)                          // version=4, IHL=5
        packet.append(0)                             // TOS
        appendUInt16(&packet, UInt16(IPv4Header.length + payload.count))
        appendUInt16(&packet, 0)                     // identification
        appendUInt16(&packet, 0x4000)                // Don't Fragment
        packet.append(64)                            // TTL
        packet.append(protocolId)
        appendUInt16(&packet, 0)                     // checksum 占位
        appendUInt32(&packet, sourceAddress)
        appendUInt32(&packet, destinationAddress)
        packet.append(payload)

        // IP 头校验和
        let checksum = internetChecksum(packet.prefix(IPv4Header.length))
        packet[10] = UInt8(checksum & 0xFF)
        packet[11] = UInt8(checksum >> 8)
        return packet
    }

    /// 追加 16 位大端值
    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    /// 追加 32 位大端值
    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// 互联网校验和（RFC 1071）
    static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count {
            sum += UInt32(bytes[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
}

// MARK: - IPv4 头解析

struct IPv4Header {
    static let length = 20

    var versionAndIHL: UInt8 = 0
    var typeOfService: UInt8 = 0
    var totalLength: UInt16 = 0
    var identification: UInt16 = 0
    var flagsAndFragment: UInt16 = 0
    var timeToLive: UInt8 = 0
    var `protocol`: UInt8 = 0
    var headerChecksum: UInt16 = 0
    /// 按大端字节序组合（10.7.0.1 → 0x0A070001）
    var sourceAddress: UInt32 = 0
    var destinationAddress: UInt32 = 0

    static func parse(_ data: Data) -> IPv4Header? {
        guard data.count >= length else { return nil }
        let bytes = [UInt8](data.prefix(length))
        guard bytes[0] >> 4 == 4 else { return nil }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard ihl >= length, data.count >= ihl else { return nil }

        var header = IPv4Header()
        header.versionAndIHL = bytes[0]
        header.typeOfService = bytes[1]
        header.totalLength = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        header.identification = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        header.flagsAndFragment = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        header.timeToLive = bytes[8]
        header.protocol = bytes[9]
        header.headerChecksum = UInt16(bytes[10]) << 8 | UInt16(bytes[11])
        header.sourceAddress = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        header.destinationAddress = UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
        return header
    }
}

// MARK: - TCP 头解析

struct TCPHeader {
    static let minLength = 20

    static let flagFIN: UInt8 = 0x01
    static let flagSYN: UInt8 = 0x02
    static let flagRST: UInt8 = 0x04
    static let flagPSH: UInt8 = 0x08
    static let flagACK: UInt8 = 0x10

    var sourcePort: UInt16 = 0
    var destinationPort: UInt16 = 0
    var sequenceNumber: UInt32 = 0
    var acknowledgmentNumber: UInt32 = 0
    var dataOffsetAndFlags: UInt16 = 0
    var window: UInt16 = 0
    var checksum: UInt16 = 0
    var urgentPointer: UInt16 = 0

    /// data offset（单位：4 字节），已转主机字节序
    var dataOffset: Int { Int(dataOffsetAndFlags >> 12) & 0xF }
    /// flags，已转主机字节序
    var flags: UInt8 { UInt8(dataOffsetAndFlags & 0x1FF) }
    var isSYN: Bool { flags & Self.flagSYN != 0 }
    var isACK: Bool { flags & Self.flagACK != 0 }
    var isFIN: Bool { flags & Self.flagFIN != 0 }
    var isRST: Bool { flags & Self.flagRST != 0 }
    var isPSH: Bool { flags & Self.flagPSH != 0 }

    /// 从 IP 包指定偏移处解析（网络字节序 → 主机字节序）
    static func parse(_ data: Data, at offset: Int) -> TCPHeader? {
        guard data.count >= offset + minLength else { return nil }
        let bytes = [UInt8](data.subdata(in: offset..<offset + minLength))

        var header = TCPHeader()
        header.sourcePort = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        header.destinationPort = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        header.sequenceNumber = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        header.acknowledgmentNumber = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        header.dataOffsetAndFlags = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        header.window = UInt16(bytes[14]) << 8 | UInt16(bytes[15])
        header.checksum = UInt16(bytes[16]) << 8 | UInt16(bytes[17])
        header.urgentPointer = UInt16(bytes[18]) << 8 | UInt16(bytes[19])
        return header
    }
}

// MARK: - TCP 代理连接（用户态 TCP 状态机）

final class TCPProxyConnection {
    private unowned let provider: PacketTunnelProvider

    let clientAddress: UInt32   // 客户端（App）IP
    let clientPort: UInt16      // 客户端源端口
    let targetPort: UInt16      // 目标端口（10.7.0.1 上的端口）

    /// 服务端（本代理）下一个发送序列号
    private var serverSeq: UInt32
    /// 客户端下一个期望序列号
    private var clientNextSeq: UInt32

    /// 真实连接（127.0.0.1）
    private var nwConnection: NWConnection?
    private let nwQueue = DispatchQueue(label: "com.sakuradebug.proxyconn")

    enum State {
        case synReceived
        case established
        case closing
        case closed
    }
    private var state: State = .synReceived

    init(provider: PacketTunnelProvider,
         clientAddress: UInt32,
         clientPort: UInt16,
         targetPort: UInt16,
         clientISN: UInt32) {
        self.provider = provider
        self.clientAddress = clientAddress
        self.clientPort = clientPort
        self.targetPort = targetPort
        self.clientNextSeq = clientISN &+ 1
        // 随机 ISN，降低被猜中的风险
        self.serverSeq = UInt32.random(in: UInt32.min...UInt32.max)
    }

    // MARK: - 握手

    func handleSYN(tcp: TCPHeader, ip: IPv4Header) {
        // 回 SYN-ACK
        sendPacket(seq: serverSeq, ack: clientNextSeq,
                   flags: TCPHeader.flagSYN | TCPHeader.flagACK, payload: Data())
        serverSeq = serverSeq &+ 1
        state = .synReceived

        // 同时发起真实连接
        connectToLoopback()
    }

    func resendSYNACK() {
        guard state == .synReceived else { return }
        sendPacket(seq: serverSeq &- 1, ack: clientNextSeq,
                   flags: TCPHeader.flagSYN | TCPHeader.flagACK, payload: Data())
    }

    private func connectToLoopback() {
        let host = NWEndpoint.Host("127.0.0.1")
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            sendRST()
            teardown()
            return
        }

        let params = NWParameters.tcp
        // 禁用 Nagle，降低调试协议的时延
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }

        let connection = NWConnection(host: host, port: port, using: params)
        nwConnection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                // 真实连接就绪，开始收数据
                self.receiveFromLoopback()
            case .failed, .cancelled:
                // 真实连接失败：RST 客户端
                if self.state != .closed {
                    self.sendRST()
                    self.teardown()
                }
            default:
                break
            }
        }
        connection.start(queue: nwQueue)
    }

    // MARK: - 客户端 → 真实服务

    func handlePacket(tcp: TCPHeader, ip: IPv4Header, payload: Data) {
        if tcp.isRST {
            // 客户端放弃：直接清理
            teardown()
            return
        }

        // 三次握手第三步：ACK 确认 SYN-ACK
        if state == .synReceived, tcp.isACK, payload.isEmpty, !tcp.isFIN {
            state = .established
            return
        }

        guard state == .established || state == .closing else { return }

        // 数据包（乱序/重复的简单处理：只接受恰好等于期望序列号的段）
        if !payload.isEmpty, tcp.isACK {
            if tcp.sequenceNumber == clientNextSeq {
                clientNextSeq = clientNextSeq &+ UInt32(payload.count)
                // 送给真实连接
                nwConnection?.send(content: payload, completion: .contentProcessed { _ in })
                // ACK 客户端
                sendPacket(seq: serverSeq, ack: clientNextSeq,
                           flags: TCPHeader.flagACK, payload: Data())
            } else if Self.seqLess(tcp.sequenceNumber, clientNextSeq) {
                // 重复段：重新 ACK
                sendPacket(seq: serverSeq, ack: clientNextSeq,
                           flags: TCPHeader.flagACK, payload: Data())
            }
            // 乱序段（seq > 期望）：丢弃，等客户端重传（简单实现，调试场景足够）
        }

        // 客户端 FIN（半关闭）
        if tcp.isFIN {
            clientNextSeq = clientNextSeq &+ 1
            sendPacket(seq: serverSeq, ack: clientNextSeq,
                       flags: TCPHeader.flagACK, payload: Data())
            state = .closing
            // 半关闭：通知对端不再有数据
            nwConnection?.send(content: nil, contentContext: .finalMessage, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - 真实服务 → 客户端

    private func receiveFromLoopback() {
        nwConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // 分段写回 TUN（不超过 MSS）
                let mss = 1440
                var offset = 0
                while offset < data.count {
                    let end = min(offset + mss, data.count)
                    let chunk = data.subdata(in: offset..<end)
                    self.sendPacket(seq: self.serverSeq,
                                    ack: self.clientNextSeq,
                                    flags: TCPHeader.flagACK | TCPHeader.flagPSH,
                                    payload: chunk)
                    self.serverSeq = self.serverSeq &+ UInt32(chunk.count)
                    offset = end
                }
            }

            if isComplete {
                // 真实连接关闭：向客户端发 FIN
                self.sendPacket(seq: self.serverSeq, ack: self.clientNextSeq,
                                flags: TCPHeader.flagFIN | TCPHeader.flagACK, payload: Data())
                self.serverSeq = self.serverSeq &+ 1
                self.state = .closing
                // 给客户端一点时间 ACK FIN 后自行清理
                self.nwQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.teardown()
                }
                return
            }

            if error != nil {
                self.sendRST()
                self.teardown()
                return
            }

            self.receiveFromLoopback()
        }
    }

    // MARK: - 关闭

    private func sendRST() {
        sendPacket(seq: serverSeq, ack: clientNextSeq,
                   flags: TCPHeader.flagRST | TCPHeader.flagACK, payload: Data())
    }

    func abort() {
        nwConnection?.cancel()
        state = .closed
    }

    private func teardown() {
        nwConnection?.cancel()
        nwConnection = nil
        state = .closed
        provider.removeConnection(port: clientPort)
    }

    // MARK: - 发包

    private func sendPacket(seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        let packet = provider.buildTCPPacket(
            sourceAddress: PacketTunnelProvider.targetIPAddress,
            destinationAddress: clientAddress,
            sourcePort: targetPort,
            destinationPort: clientPort,
            seq: seq,
            ack: ack,
            flags: flags,
            payload: payload
        )
        provider.writePacket(packet)
    }

    /// 序列号回绕安全比较：a < b（RFC 1323）
    private static func seqLess(_ a: UInt32, _ b: UInt32) -> Bool {
        let diff = a &- b
        return diff != 0 && diff & 0x8000_0000 != 0
    }
}
