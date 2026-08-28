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

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        try await DirectHTTP.request(url: url, method: method, headers: headers, body: body, timeout: timeout)
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
