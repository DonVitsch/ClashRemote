import Foundation
import CoreFoundation

enum HTTPError: LocalizedError {
    case badURL
    case httpStatus(Int, String)
    case empty
    case json
    case ubus(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "地址无效"
        case .httpStatus(let code, let body):
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty { return "HTTP \(code)" }
            return "HTTP \(code)：\(snippet.prefix(160))"
        case .empty:
            return "空响应"
        case .json:
            return "返回不是 JSON"
        case .ubus(let code):
            return "ubus 错误 \(code)"
        case .message(let s):
            return s
        }
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var data: Data
    var headers: [String: String]

    var text: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func jsonObject() throws -> Any {
        guard !data.isEmpty else { throw HTTPError.empty }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HTTPError.json
        }
    }

    func jsonDict() throws -> [String: Any] {
        let obj = try jsonObject()
        guard let dict = obj as? [String: Any] else { throw HTTPError.json }
        return dict
    }
}

final class HTTPClient: @unchecked Sendable {
    private let timeout: TimeInterval
    private let session: URLSession

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        // 空代理字典 = 强制不走系统代理（FlClash/Clash），直连内网路由器
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldUsePipelining = true
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> HTTPResponse {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout ?? self.timeout)
        req.httpMethod = method
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.empty
        }
        var hdrs: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let k = key as? String, let v = value as? String else { continue }
            let lower = k.lowercased()
            if let existing = hdrs[lower] {
                hdrs[lower] = existing + "\n" + v
            } else {
                hdrs[lower] = v
            }
        }
        return HTTPResponse(status: http.statusCode, data: data, headers: hdrs)
    }

    func jsonRPC(url: URL, payload: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload)
        var next = headers
        next["Content-Type"] = "application/json"
        let response = try await request(url: url, method: "POST", headers: next, body: body)
        if response.status >= 400 {
            throw HTTPError.httpStatus(response.status, response.text)
        }
        return try response.jsonDict()
    }
}

/// 不自动跟随 3xx 重定向：luciLogin 的 302 响应里带 sysauth cookie，必须原样返回不能被 follow 掉。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum JSONValue {
    static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let b = any as? Bool { return b ? "1" : "0" }
        return ""
    }

    static func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.intValue != 0 }
        let s = string(any).lowercased()
        return s == "1" || s == "true" || s == "yes" || s == "on"
    }

    static func int(_ any: Any?, fallback: Int = 0) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return Int(string(any)) ?? fallback
    }

    static func dict(_ any: Any?) -> [String: Any] {
        any as? [String: Any] ?? [:]
    }

    static func array(_ any: Any?) -> [Any] {
        any as? [Any] ?? []
    }
}
