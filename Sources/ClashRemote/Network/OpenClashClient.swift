import Foundation

@MainActor
final class OpenClashClient {
    let device: RouterDevice
    let http = HTTPClient()

    private(set) var ubusSid = ""
    private(set) var luciCookie = ""
    private(set) var clashSecret = ""
    private(set) var clashPort = 9090

    init(device: RouterDevice) {
        self.device = device
    }

    var luciBase: URL { device.baseURL }
    var ubusURL: URL { luciBase.appending(path: "ubus") }

    func login() async throws {
        try await ubusLogin()
        try await luciLogin()
    }

    func ubusLogin() async throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "call",
            "params": [
                "00000000000000000000000000000000",
                "session",
                "login",
                ["username": device.username, "password": device.password]
            ]
        ]
        let json = try await http.jsonRPC(url: ubusURL, payload: payload)
        guard let result = json["result"] as? [Any],
              let code = result.first as? Int
        else { throw HTTPError.message("登录失败") }
        if code != 0 {
            throw HTTPError.message("用户名或密码错误")
        }
        let data = JSONValue.dict(result.dropFirst().first)
        let sid = JSONValue.string(data["ubus_rpc_session"])
        if sid.isEmpty { throw HTTPError.message("没有拿到会话") }
        ubusSid = sid
    }

    func luciLogin() async throws {
        var components = URLComponents(url: luciBase.appending(path: "cgi-bin/luci/"), resolvingAgainstBaseURL: false)
        components?.queryItems = nil
        guard let url = components?.url else { throw HTTPError.badURL }
        let body = form([
            "luci_username": device.username,
            "luci_password": device.password
        ])
        let response = try await http.request(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: body
        )
        if let cookie = cookieValue(from: response, name: "sysauth_http")
            ?? cookieValue(from: response, name: "sysauth")
            ?? cookieValue(from: response, name: "sysauth_https") {
            luciCookie = cookie
        }
        if luciCookie.isEmpty, (200..<400).contains(response.status) {
            // Cookie jar may have stored it; later requests still work.
        }
    }

    func refreshIfNeeded() async throws {
        if ubusSid.isEmpty { try await ubusLogin() }
        if luciCookie.isEmpty { try await luciLogin() }
    }

    func ubus(object: String, method: String, params: [String: Any] = [:]) async throws -> Any {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "call",
            "params": [ubusSid, object, method, params]
        ]
        let json = try await http.jsonRPC(url: ubusURL, payload: payload)
        guard let result = json["result"] as? [Any],
              let code = result.first as? Int
        else { throw HTTPError.ubus(-1) }
        if code != 0 { throw HTTPError.ubus(code) }
        return result.dropFirst().first ?? [:]
    }

    func uciGet(config: String) async throws -> [String: [String: Any]] {
        let data = JSONValue.dict(try await ubus(object: "uci", method: "get", params: ["config": config]))
        return JSONValue.dict(data["values"]) as? [String: [String: Any]] ?? {
            var out: [String: [String: Any]] = [:]
            for (k, v) in JSONValue.dict(data["values"]) {
                out[k] = JSONValue.dict(v)
            }
            return out
        }()
    }

    func uciSet(config: String, section: String, values: [String: Any]) async throws {
        _ = try await ubus(
            object: "uci",
            method: "set",
            params: ["config": config, "section": section, "values": values]
        )
    }

    func uciAdd(config: String, type: String, values: [String: Any]) async throws -> String {
        let data = try await ubus(
            object: "uci",
            method: "add",
            params: ["config": config, "type": type, "values": values]
        )
        if let s = data as? String { return s }
        return JSONValue.string(JSONValue.dict(data)["section"])
    }

    func uciDelete(config: String, section: String) async throws {
        _ = try await ubus(
            object: "uci",
            method: "delete",
            params: ["config": config, "section": section]
        )
    }

    func uciCommit(config: String) async throws {
        _ = try await ubus(object: "uci", method: "commit", params: ["config": config])
    }

    func luciGet(_ path: String, query: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var components = URLComponents(
            url: luciBase.appending(path: "cgi-bin/luci/\(path)"),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw HTTPError.badURL }
        let response = try await http.request(url: url, headers: luciHeaders(), timeout: timeout)
        return try decodeLuCI(response)
    }

    func luciPostForm(_ path: String, fields: [String: String], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let url = luciBase.appending(path: "cgi-bin/luci/\(path)")
        var headers = luciHeaders()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let response = try await http.request(
            url: url,
            method: "POST",
            headers: headers,
            body: form(fields),
            timeout: timeout
        )
        return try decodeLuCI(response)
    }

    private func luciHeaders() -> [String: String] {
        guard !luciCookie.isEmpty else { return [:] }
        return ["Cookie": "sysauth_http=\(luciCookie); sysauth=\(luciCookie); sysauth_https=\(luciCookie)"]
    }

    private func decodeLuCI(_ response: HTTPResponse) throws -> [String: Any] {
        if response.status == 403 || response.status == 401 {
            throw HTTPError.message("LuCI 会话失效，请重新连接")
        }
        if response.status >= 400 {
            throw HTTPError.httpStatus(response.status, response.text)
        }
        if response.data.isEmpty { return [:] }
        let text = response.text
        if text.localizedCaseInsensitiveContains("login") && text.localizedCaseInsensitiveContains("<html") {
            throw HTTPError.message("LuCI 会话失效，请重新连接")
        }
        if let obj = try? response.jsonObject() {
            return obj as? [String: Any] ?? ["value": obj]
        }
        return ["raw": text]
    }

    func loadClashEndpoint(from status: [String: Any], uci: [String: [String: Any]]) {
        let config = uci["config"] ?? [:]
        let port = JSONValue.int(status["cn_port"], fallback: JSONValue.int(config["cn_port"], fallback: 9090))
        clashPort = port == 0 ? 9090 : port
        let secret = JSONValue.string(status["dase"])
        clashSecret = secret.isEmpty ? JSONValue.string(config["dashboard_password"]) : secret
    }

    func clashURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = device.host
        components.port = clashPort
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw HTTPError.badURL }
        return url
    }

    func fileRead(_ path: String) async throws -> String {
        let data = JSONValue.dict(try await ubus(object: "file", method: "read", params: ["path": path]))
        return JSONValue.string(data["data"])
    }

    func fileWrite(_ path: String, contents: String) async throws {
        _ = try await ubus(
            object: "file",
            method: "write",
            params: ["path": path, "data": contents]
        )
    }

    @discardableResult
    func fileExec(_ command: String, timeoutMS: Int = 15_000) async throws -> String {
        let data = JSONValue.dict(
            try await ubus(
                object: "file",
                method: "exec",
                params: [
                    "command": "/bin/sh",
                    "params": ["-c", command]
                ]
            )
        )
        let stdout = JSONValue.string(data["stdout"])
        let stderr = JSONValue.string(data["stderr"])
        let code = JSONValue.int(data["code"])
        if code != 0, stdout.isEmpty {
            throw HTTPError.message(stderr.isEmpty ? "路由器命令失败 (\(code))" : stderr)
        }
        return stdout.isEmpty ? stderr : stdout
    }

    func clashRequest(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        json: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> HTTPResponse {
        let url = try clashURL(path, query: query)
        var headers = ["Authorization": "Bearer \(clashSecret)"]
        var body: Data?
        if let json {
            headers["Content-Type"] = "application/json"
            body = try JSONSerialization.data(withJSONObject: json)
        }
        let response = try await http.request(url: url, method: method, headers: headers, body: body, timeout: timeout)
        if response.status >= 400 {
            throw HTTPError.httpStatus(response.status, response.text)
        }
        return response
    }

    private func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    private func cookieValue(from response: HTTPResponse, name: String) -> String? {
        guard let setCookie = response.headers["set-cookie"] ?? response.headers["Set-Cookie"] else {
            return nil
        }
        for line in setCookie.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            if let value = parseCookie(String(line), name: name) {
                return value
            }
        }
        return parseCookie(setCookie, name: name)
    }

    private func parseCookie(_ line: String, name: String) -> String? {
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name {
                return String(pair[1])
            }
        }
        return nil
    }
}
