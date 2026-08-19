//
//  AnisetteService.swift
//  SakuraDeBug
//
//  远程 Anisette 服务器支持：从用户配置的 URL 实时拉取 Anisette 数据，
//  免去每次认证前从 SideStore/AltServer 手动导出 JSON 的麻烦。
//
//  适配两类常见服务器响应格式：
//  ① 直接返回 Anisette 字典（如 { "machineID":..., "oneTimePassword":... }）
//  ② 包装在 result / data 字段里（如 { "result": { ... } }，SideStore 公共服务器常用）
//

import Foundation
import Combine

@MainActor
final class AnisetteService: ObservableObject {
    static let shared = AnisetteService()

    // MARK: - 持久化配置

    /// 是否启用「从服务器拉取」模式（关闭则回退到手动导入 JSON）
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    /// Anisette 服务器地址（完整 URL，含 https://）
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.url) }
    }

    // MARK: - 运行时状态

    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var cachedData: [String: String]?

    /// 服务器返回数据里「看起来像 Anisette 字段」的最小校验集合。
    /// ALTAnisetteData(json:) 在 AltSign 里会做完整校验，这里只做前置过滤，
    /// 避免把明显不是 anisette 的响应（HTML 错误页等）当作有效数据。
    private static let requiredKeys: Set<String> = [
        "machineID", "oneTimePassword", "localUserID", "deviceID"
    ]

    private let defaults = UserDefaults.standard
    private let session: URLSession

    private struct Keys {
        static let enabled = "anisette.server.enabled"
        static let url = "anisette.server.url"
    }

    private init() {
        self.enabled = defaults.bool(forKey: Keys.enabled)
        // 首次默认填一个 SideStore 社区公共服务器，方便用户直接试。
        // 用户可改成自建/私有地址。注意：公共服务器容易被风控，仅作入门默认。
        let saved = UserDefaults.standard.string(forKey: Keys.url) ?? ""
        self.serverURL = saved.isEmpty
            ? "https://ani.sidestore.dev/ani"
            : saved

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 拉取

    /// 从服务器拉取最新 Anisette 数据。
    /// Anisette 里的 OTP 时间敏感（约每 30s 轮换），所以默认每次都真拉取，
    /// 不返回过期缓存——只在网络失败时回退到最近的缓存（若有且未超 60s）。
    func fetchAnisette() async throws -> [String: String] {
        guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AnisetteServerError.emptyURL
        }

        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            throw AnisetteServerError.invalidURL
        }

        // 仅 https/http，防止 file:// 等 scheme 误用
        guard url.scheme == "http" || url.scheme == "https" else {
            throw AnisetteServerError.invalidURL
        }

        isFetching = true
        defer { isFetching = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("SakuraDeBug", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw AnisetteServerError.serverError(code)
            }

            guard let parsed = Self.parseAnisetteResponse(data) else {
                throw AnisetteServerError.invalidJSON
            }

            cachedData = parsed
            lastFetchDate = Date()
            lastError = nil
            return parsed
        } catch is CancellationError {
            throw AnisetteServerError.cancelled
        } catch let err as AnisetteServerError {
            lastError = err.errorDescription
            // 网络失败时回退到 60s 内的缓存（OTP 可能已失效，但比完全无数据强）
            if let cached = cachedData, let date = lastFetchDate, Date().timeIntervalSince(date) < 60 {
                return cached
            }
            throw err
        } catch {
            lastError = error.localizedDescription
            if let cached = cachedData, let date = lastFetchDate, Date().timeIntervalSince(date) < 60 {
                return cached
            }
            throw AnisetteServerError.networkFailure(error.localizedDescription)
        }
    }

    /// 测试连接：只拉取一次，不抛异常，把结果写回 lastError/lastFetchDate。
    /// 供 UI 的「测试连接」按钮使用，成功返回 true。
    @discardableResult
    func testConnection() async -> Bool {
        do {
            _ = try await fetchAnisette()
            return true
        } catch {
            lastError = (error as? AnisetteServerError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    // MARK: - 解析

    /// 解析服务器响应，兼容三种结构：
    /// ① 顶层即为 Anisette 字典
    /// ② { "result": { ... } }
    /// ③ { "data": { ... } }
    /// 同时兼容字段值被包成字符串（某些服务器把 OTP 包成 "xxx"）。
    private static func parseAnisetteResponse(_ data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(
            with: data, options: [.allowFragments]
        ) else { return nil }

        // 候选字典：先取 result/data 包装层，取不到就用顶层
        var candidate: [String: Any]?
        if let dict = json as? [String: Any] {
            if let inner = dict["result"] as? [String: Any] {
                candidate = inner
            } else if let inner = dict["data"] as? [String: Any] {
                candidate = inner
            } else {
                candidate = dict
            }
        }

        guard let dict = candidate else { return nil }

        // 把所有值统一转成 String（数字也转），AltSign 的 ALTAnisetteData(json:) 期望 [String: String]
        var stringDict: [String: String] = [:]
        for (k, v) in dict {
            switch v {
            case let s as String: stringDict[k] = s
            case let n as NSNumber: stringDict[k] = n.stringValue
            default: stringDict[k] = "\(v)"
            }
        }

        // 前置字段校验：缺少任一关键字段就判定无效
        for key in requiredKeys where stringDict[key] == nil {
            return nil
        }
        return stringDict
    }
}

enum AnisetteServerError: LocalizedError {
    case emptyURL
    case invalidURL
    case invalidJSON
    case serverError(Int)
    case networkFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Anisette 服务器地址为空，请在「Anisette 来源」里填写服务器 URL。"
        case .invalidURL:
            return "Anisette 服务器地址无效：需以 http:// 或 https:// 开头的完整 URL。"
        case .invalidJSON:
            return "服务器返回的内容不是有效的 Anisette 数据（缺少 machineID/oneTimePassword 等必需字段）。"
        case .serverError(let code):
            return "Anisette 服务器返回错误（HTTP \(code)）。请检查地址是否正确，或服务器是否在线。"
        case .networkFailure(let detail):
            return "连接 Anisette 服务器失败：\(detail)"
        case .cancelled:
            return "Anisette 拉取已取消。"
        }
    }
}
