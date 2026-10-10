import Foundation
import CommonCrypto

/// UFI-TOOLS (port 2333) signed HTTP + root shell.
@MainActor
final class UFIClient {
    let device: RouterDevice
    private let http = HTTPClient(timeout: 20)
    private let secret = "minikano_kOyXz0Ciz4V7wR0IeKmJFYFQ20jd"

    init(device: RouterDevice) {
        self.device = device
    }

    var token: String {
        sha256Hex(device.password.data(using: .utf8) ?? Data())
    }

    func rootShell(_ command: String, timeoutMS: Int = 20_000) async throws -> String {
        let json = try await signedJSON(
            path: "/api/root_shell",
            method: "POST",
            body: ["command": command, "timeout": timeoutMS]
        )
        if let error = json["error"] as? String, !error.isEmpty {
            throw HTTPError.message(error)
        }
        if let result = json["result"] as? String {
            return result
        }
        if let result = json["content"] as? String {
            return result
        }
        // 绝不能把"没拿到结果"当成空字符串返回：调用方（如读配置再写回）会把
        // 读取失败误判成"文件是空的"，从而用空内容覆盖掉路由器上的好配置。
        throw HTTPError.message("路由器没有返回内容，命令可能超时或输出过大，请重试。")
    }

    /// 读文件。
    ///
    /// **必须带重试**：内核重启时 clashctl 会重写、甚至短暂移走 config.yaml，
    /// 后续步骤恰好撞上那个窗口就会误报「文件不存在 / 读取不完整」——
    /// 之前就因为这个把「收敛策略组」这一步白白跳过了。
    func readFile(_ path: String) async throws -> String {
        var lastError: Error = HTTPError.message("路由器上没有 \(path)")
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                return try await readFileOnce(path)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func readFileOnce(_ path: String) async throws -> String {
        let escaped = shellEscape(path)
        // 不能按字节数校验：root shell 的输出是走 $(...) 捕获回来的，会吞掉文件末尾的换行，
        // 于是"9428 字节的文件只回来 9427 字节"这种差 1 字节的假失败会出现。
        // 改成比对"双方都去掉末尾换行后"的 md5，能真正判断内容有没有被截断。
        let digest = try await rootShell(
            "if [ -f \(escaped) ]; then printf '%s' \"$(cat \(escaped))\" | md5sum | cut -d' ' -f1; else echo MISSING; fi",
            timeoutMS: 30_000
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if digest == "MISSING" {
            throw HTTPError.message("路由器上没有 \(path)")
        }
        guard digest.count == 32 else {
            throw HTTPError.message("无法校验 \(path) 的内容，已中止读取。")
        }
        let text = try await rootShell("cat \(escaped)", timeoutMS: 30_000)
        guard md5Hex(text) == digest else {
            throw HTTPError.message("\(path) 读取不完整（内容校验不一致），已中止，未做任何修改。")
        }
        return text
    }

    private func md5Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func writeFile(_ path: String, contents: String) async throws {
        guard let data = contents.data(using: .utf8) else {
            throw HTTPError.message("配置编码失败")
        }
        let b64 = data.base64EncodedString()
        let cmd = """
        printf '%s' '\(b64)' | (base64 -d 2>/dev/null || base64 -D) > \(shellEscape(path))
        """
        _ = try await rootShell(cmd, timeoutMS: 60_000)
        // 写完必须核对落盘大小：大文件经 root shell 传输有被截断的风险，
        // 静默截断会让核心起不来而且没人知道原因。
        let landSize = try await rootShell(
            "wc -c < \(shellEscape(path))",
            timeoutMS: 10_000
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let landed = Int(landSize), landed == data.count else {
            throw HTTPError.message("写入 \(path) 后大小不符（期望 \(data.count) 字节，实际 \(landSize) 字节），配置可能已损坏。")
        }
    }

    private func signedJSON(path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let response = try await signedRequest(path: path, method: method, body: body)
        if response.status >= 400 {
            throw HTTPError.httpStatus(response.status, response.text.isEmpty ? "UFI 认证失败" : response.text)
        }
        if response.data.isEmpty { return [:] }
        return try response.jsonDict()
    }

    private func signedRequest(path: String, method: String, body: [String: Any]?) async throws -> HTTPResponse {
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let signPath = path.split(separator: "?").first.map(String.init) ?? path
        let signature = ufiSign(method: method.uppercased(), path: signPath, timestamp: ts)
        var headers = [
            "authorization": token,
            "kano-t": ts,
            "kano-sign": signature
        ]
        var data: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            data = try JSONSerialization.data(withJSONObject: body)
        }
        var components = URLComponents()
        components.scheme = device.useHTTPS ? "https" : "http"
        components.host = device.host
        components.port = device.port
        components.path = path
        guard let url = components.url else { throw HTTPError.badURL }
        return try await http.request(url: url, method: method, headers: headers, body: data)
    }

    private func ufiSign(method: String, path: String, timestamp: String) -> String {
        let raw = Data("minikano\(method)\(path)\(timestamp)".utf8)
        let digest = hmacMD5(key: Data(secret.utf8), message: raw)
        let mid = digest.count / 2
        let sha1 = sha256(digest.prefix(mid))
        let sha2 = sha256(digest.suffix(digest.count - mid))
        return sha256Hex(sha1 + sha2)
    }

    private func hmacMD5(key: Data, message: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            message.withUnsafeBytes { msgPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgMD5),
                    keyPtr.baseAddress,
                    key.count,
                    msgPtr.baseAddress,
                    message.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    private func sha256Hex(_ data: Data) -> String {
        sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    private func shellEscape(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
