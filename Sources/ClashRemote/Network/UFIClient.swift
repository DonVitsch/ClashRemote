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
        return ""
    }

    func readFile(_ path: String) async throws -> String {
        try await rootShell("cat \(shellEscape(path))", timeoutMS: 15_000)
    }

    func writeFile(_ path: String, contents: String) async throws {
        guard let data = contents.data(using: .utf8) else {
            throw HTTPError.message("配置编码失败")
        }
        let b64 = data.base64EncodedString()
        let cmd = """
        printf '%s' '\(b64)' | (base64 -d 2>/dev/null || base64 -D) > \(shellEscape(path))
        """
        _ = try await rootShell(cmd, timeoutMS: 20_000)
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
