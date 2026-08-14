//
//  WebConsoleServer.swift
//  SakuraDeBug
//
//  局域网网页控制台：App 内置轻量 HTTP 服务器（Network.framework 实现，零第三方依赖），
//  同一 WiFi 下的电脑浏览器可实时查看自配对状态、PIN 码与日志，并下载配对文件。
//  用法：电脑浏览器打开 http://<设备IP>:<端口>/?k=<token>
//  安全：启动时生成随机 token，所有请求必须携带 ?k=token 才会响应。
//

import Foundation
import Network

/// 局域网网页控制台服务器（GET-only，轻量 HTTP/1.1）。
/// 端口从 8080 起，被占用自动递增；启动时生成访问 token。
@MainActor
final class WebConsoleServer: ObservableObject {

    static let shared = WebConsoleServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var token = ""

    /// 电脑浏览器访问地址（监听就绪后有效）
    var accessURL: String? {
        guard isRunning, port > 0, !token.isEmpty else { return nil }
        return "http://\(Self.localIPAddress ?? "设备IP"):\(port)/?k=\(token)"
    }

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]

    private init() {}

    func start() {
        guard !isRunning else { return }
        token = String(UUID().uuidString.prefix(8))
        tryStart(port: 8080)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values {
            session.connection.cancel()
        }
        sessions.removeAll()
        isRunning = false
        port = 0
    }

    // MARK: - 监听

    private func tryStart(port candidate: UInt16) {
        guard candidate < 65535 else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: candidate)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerStateChanged(state, candidate: candidate)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            tryStart(port: candidate + 1)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State, candidate: UInt16) {
        switch state {
        case .ready:
            isRunning = true
            port = candidate
        case .failed:
            if let listener {
                listener.cancel()
                self.listener = nil
            }
            isRunning = false
            if candidate < 65534 {
                tryStart(port: candidate + 1)
            }
        default:
            break
        }
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        let session = Session(connection: connection)
        sessions[session.id] = session
        receiveMore(session)
    }

    private func receiveMore(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            Task { @MainActor in
                self.process(session, data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func process(_ session: Session, data: Data?, isComplete: Bool, error: Error?) {
        if let data, !data.isEmpty {
            session.buffer.append(data)
        }

        if let end = session.buffer.range(of: Self.headerEnd) {
            defer { close(session) }
            let head = session.buffer[..<end.lowerBound]
            guard let request = Self.parseRequest(head), isAuthorized(request) else {
                respond(session.connection, status: "404 Not Found", contentType: "text/plain", body: Data())
                return
            }
            route(request, connection: session.connection)
            return
        }

        if error != nil || isComplete || session.buffer.count > 65536 {
            close(session)
            return
        }

        receiveMore(session)
    }

    private func close(_ session: Session) {
        sessions[session.id] = nil
        session.connection.cancel()
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    // MARK: - 路由

    private func route(_ request: HTTPRequest, connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(connection,
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    body: Data(Self.consoleHTML.utf8))
        case ("GET", "/api/status"):
            respond(connection,
                    status: "200 OK",
                    contentType: "application/json; charset=utf-8",
                    body: statusJSON())
        case ("GET", "/api/pairing-file"):
            servePairingFile(connection)
        default:
            respond(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func servePairingFile(_ connection: NWConnection) {
        let url = PairingFileStore.url
        guard let data = try? Data(contentsOf: url) else {
            respond(connection, status: "404 Not Found", contentType: "text/plain", body: Data("配对文件尚未生成".utf8))
            return
        }
        respond(connection,
                status: "200 OK",
                contentType: "application/octet-stream",
                body: data,
                extraHeaders: ["Content-Disposition: attachment; filename=\"pairingFile.plist\""])
    }

    private func statusJSON() -> Data {
        let controller = SelfPairingController.shared
        var pin: String?
        if case .showPin(let value) = controller.phase {
            pin = value
        }
        let payload = StatusPayload(
            phase: Self.phaseName(controller.phase),
            pin: pin,
            deviceName: controller.deviceName,
            deviceUDID: controller.deviceUDID,
            hasPairingFile: PairingFileStore.hasPairingFile,
            port: port,
            logs: Array(controller.logHistory.suffix(200)))
        return (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
    }

    private struct StatusPayload: Encodable {
        let phase: String
        let pin: String?
        let deviceName: String
        let deviceUDID: String
        let hasPairingFile: Bool
        let port: UInt16
        let logs: [String]
    }

    private static func phaseName(_ phase: SelfPairingController.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .showPin: return "showPin"
        case .success: return "success"
        case .failed: return "failed"
        }
    }

    // MARK: - HTTP 请求解析 / 响应

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: String
    }

    private static func parseRequest(_ head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pieces.first.map(String.init) ?? target
        let query = pieces.count > 1 ? String(pieces[1]) : ""
        return HTTPRequest(method: method, path: path, query: query)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let expected = "k=" + token
        return request.query.split(separator: "&").contains { String($0) == expected }
    }

    private func respond(_ connection: NWConnection,
                         status: String,
                         contentType: String,
                         body: Data,
                         extraHeaders: [String] = []) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        for extra in extraHeaders {
            header += extra + "\r\n"
        }
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    /// 单个连接的接收缓冲（仅 @MainActor 内访问）
    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let id: ObjectIdentifier
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
            self.id = ObjectIdentifier(connection)
        }
    }

    // MARK: - 本机 IP

    /// 取 en0/en1 的 IPv4 地址（热点/路由器场景常见），用于拼接控制台地址
    static var localIPAddress: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    _ = getnameinfo(interface.ifa_addr,
                                    socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &host,
                                    socklen_t(host.count),
                                    nil, 0, NI_NUMERICHOST)
                    if let ip = String(cString: host, encoding: .utf8), !ip.hasPrefix("127.") {
                        address = ip
                        break
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }

    // MARK: - 控制台页面

    private static let consoleHTML = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SakuraDeBug 控制台</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;background:linear-gradient(160deg,#fff0f4,#f3ecfb);min-height:100vh;color:#5e3844;padding:26px 16px}
.card{background:rgba(255,255,255,.86);border:1px solid rgba(255,115,158,.30);border-radius:20px;padding:22px;max-width:560px;margin:0 auto 14px}
h1{font-size:20px;font-weight:700;color:#c24a78}
.sub{font-size:12px;color:rgba(94,56,68,.55);margin-top:3px}
.statusline{display:flex;align-items:center;gap:10px;margin-top:14px;flex-wrap:wrap}
.dot{width:10px;height:10px;border-radius:50%;background:#bbb}
.dot.on{background:#2ecc71}
.dot.wait{background:#f39c12;animation:pulse 1.2s infinite}
.dot.err{background:#e74c3c}
@keyframes pulse{50%{opacity:.35}}
.badge{font-size:13px;padding:4px 12px;border-radius:999px;background:rgba(255,115,158,.14);color:#c24a78;font-weight:600}
.pin{font-size:46px;font-weight:800;letter-spacing:12px;color:#ff739e;text-align:center;margin:16px 0 6px;font-family:'SF Mono',Menlo,monospace}
.pinhint{font-size:12px;text-align:center;color:rgba(94,56,68,.55)}
.muted{font-size:12px;color:rgba(94,56,68,.62);line-height:1.7}
.divider{height:1px;background:rgba(255,115,158,.18);margin:14px 0}
.log{background:rgba(255,255,255,.72);border:1px solid rgba(255,115,158,.16);border-radius:12px;padding:12px;font:11px/1.7 Menlo,Consolas,monospace;height:210px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.loghead{font-size:12px;color:rgba(94,56,68,.6);margin-bottom:8px;font-weight:600}
a.btn{display:block;text-align:center;padding:12px;border-radius:12px;background:#ff739e;color:#fff;text-decoration:none;font-weight:600;margin-top:14px;font-size:14px}
a.btn:active{opacity:.8}
.foot{text-align:center;font-size:11px;color:rgba(94,56,68,.4);margin-top:18px}
</style>
</head>
<body>
<div class="card">
  <h1>SakuraDeBug · 网页控制台</h1>
  <div class="sub">同一 WiFi 下实时查看自配对状态与配对文件</div>
  <div class="statusline"><span class="dot" id="dot"></span><span class="badge" id="phase">连接中…</span></div>
  <div class="pin" id="pin" style="display:none"></div>
  <div class="pinhint" id="pinhint" style="display:none">请在设备「设置 › 隐私与安全 › 开发者模式」输入上方配对码</div>
  <div class="muted" id="info" style="margin-top:12px"></div>
  <div id="downloadArea"></div>
</div>
<div class="card">
  <div class="loghead">实时日志</div>
  <div class="log" id="log">等待数据…</div>
</div>
<div class="foot">SakuraDeBug · 仅限可信网络使用</div>
<script>
var qs = new URLSearchParams(location.search);
var k = qs.get('k') || '';
function u(p){ return p + (k ? (p.indexOf('?') >= 0 ? '&' : '?') + 'k=' + encodeURIComponent(k) : ''); }
function $(id){ return document.getElementById(id); }
function esc(s){ var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
var ph = { idle:'未开始', waiting:'等待配对…', showPin:'输入 PIN 中', success:'配对成功', failed:'配对失败' };
async function tick(){
  try{
    var r = await fetch(u('/api/status'), { cache:'no-store' });
    var s = await r.json();
    $('phase').textContent = ph[s.phase] || s.phase;
    var dot = $('dot');
    dot.className = 'dot' + (s.phase === 'waiting' || s.phase === 'showPin' ? ' wait' : s.phase === 'success' ? ' on' : s.phase === 'failed' ? ' err' : '');
    if (s.phase === 'showPin' && s.pin){
      $('pin').style.display = 'block'; $('pin').textContent = s.pin;
      $('pinhint').style.display = 'block';
    } else {
      $('pin').style.display = 'none'; $('pinhint').style.display = 'none';
    }
    var info = '';
    if (s.deviceName) info += '设备：' + esc(s.deviceName) + '（' + esc(s.deviceUDID) + '）<br>';
    info += '配对文件：' + (s.hasPairingFile ? '已就绪' : '未生成') + '<br>';
    info += '端口：' + s.port;
    $('info').innerHTML = info;
    $('downloadArea').innerHTML = s.hasPairingFile
      ? '<a class="btn" href="' + u('/api/pairing-file') + '" download>下载配对文件</a>'
      : '';
    var log = $('log');
    var auto = log.scrollTop + log.clientHeight >= log.scrollHeight - 10;
    log.textContent = s.logs.join('\n');
    if (auto) log.scrollTop = log.scrollHeight;
  }catch(e){
    $('phase').textContent = '无法连接服务器';
    $('dot').className = 'dot err';
  }
}
tick();
setInterval(tick, 1000);
</script>
</body>
</html>
"""#
}
