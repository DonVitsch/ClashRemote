import Foundation
import Network

/// Talks HTTP over raw TCP so system Clash/FlClash proxies cannot hijack LAN router calls.
enum DirectHTTP {
    static func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        guard let host = url.host else { throw HTTPError.badURL }
        let portValue = UInt16(url.port ?? ((url.scheme == "https") ? 443 : 80))
        guard let port = NWEndpoint.Port(rawValue: portValue) else { throw HTTPError.badURL }


        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout / 2))
        tcp.noDelay = true
        let tls: NWProtocolTLS.Options? = (url.scheme == "https") ? NWProtocolTLS.Options() : nil
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        parameters.expiredDNSBehavior = .allow
        parameters.prohibitedInterfaceTypes = []

        let connection = NWConnection(host: .init(host), port: port, using: parameters)
        do {
            try await connect(connection, timeout: timeout)
        } catch {
            connection.cancel()
            throw error
        }
        defer { connection.cancel() }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        var headerLines: [String] = [
            "\(method.uppercased()) \(path) HTTP/1.1",
            "Host: \(host)\(url.port == nil ? "" : ":\(portValue)")",
            "Connection: close",
            "Accept: */*",
            "User-Agent: ClashRemote/1.0"
        ]
        var sent = headers
        if let body, sent["Content-Length"] == nil && sent["content-length"] == nil {
            sent["Content-Length"] = "\(body.count)"
        }
        for (key, value) in sent {
            headerLines.append("\(key): \(value)")
        }
        var payload = headerLines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        payload.append(contentsOf: [13, 10, 13, 10])
        if let body { payload.append(body) }

        try await send(connection, payload)
        let parsed = try await receiveResponse(connection, timeout: timeout)
        return parsed
    }

    private static func connect(_ connection: NWConnection, timeout: TimeInterval) async throws {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        cont.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        cont.resume(throwing: error)
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        cont.resume(throwing: HTTPError.message("连接取消"))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private static func receiveResponse(_ connection: NWConnection, timeout: TimeInterval) async throws -> HTTPResponse {
        try await withTimeout(timeout) {
            var collected = Data()
            while true {
                let part: (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        cont.resume(returning: (content, isComplete))
                    }
                }
                if let data = part.0, !data.isEmpty {
                    collected.append(data)
                }
                if let parsed = try? parseIfComplete(collected) {
                    return parsed
                }
                if part.1 || part.0 == nil {
                    if let parsed = try parseIfComplete(collected) {
                        return parsed
                    }
                    throw HTTPError.message("HTTP 响应不完整")
                }
                if collected.count > 8_000_000 {
                    throw HTTPError.message("响应过大")
                }
            }
        }
    }

    private static func parseIfComplete(_ raw: Data) throws -> HTTPResponse? {
        let separator = Data([13, 10, 13, 10])
        guard let range = raw.range(of: separator) else { return nil }
        let head = String(data: raw.subdata(in: raw.startIndex..<range.lowerBound), encoding: .isoLatin1) ?? ""
        var body = raw.subdata(in: range.upperBound..<raw.endIndex)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw HTTPError.empty }
        let statusParts = statusLine.split(separator: " ")
        let status = statusParts.dropFirst().first.flatMap { Int($0) } ?? 0

        var headers: [String: String] = [:]
        var contentLength: Int?
        var chunked = false
        for line in lines.dropFirst() {
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let headerKey = key.lowercased()
            if let existing = headers[headerKey] {
                headers[headerKey] = existing + "\n" + value
            } else {
                headers[headerKey] = value
            }
            if headerKey == "content-length" {
                contentLength = Int(value)
            }
            if headerKey == "transfer-encoding", value.lowercased().contains("chunked") {
                chunked = true
            }
        }

        if chunked {
            guard let decoded = decodeChunkedIfComplete(body) else { return nil }
            return HTTPResponse(status: status, data: decoded, headers: headers)
        }
        if let contentLength {
            if body.count < contentLength { return nil }
            body = Data(body.prefix(contentLength))
            return HTTPResponse(status: status, data: body, headers: headers)
        }
        if status == 204 || status == 304 || (status >= 100 && status < 200) {
            return HTTPResponse(status: status, data: Data(), headers: headers)
        }
        return nil
    }

    private static func decodeChunkedIfComplete(_ data: Data) -> Data? {
        var input = data
        var output = Data()
        while !input.isEmpty {
            guard let nl = input.range(of: Data([13, 10])) else { return nil }
            let sizeLine = String(data: input.subdata(in: input.startIndex..<nl.lowerBound), encoding: .isoLatin1) ?? "0"
            let sizeHex = sizeLine.split(separator: ";").first.map(String.init) ?? "0"
            let size = Int(sizeHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) ?? 0
            input = input.subdata(in: nl.upperBound..<input.endIndex)
            if size == 0 { return output }
            guard input.count >= size + 2 else { return nil }
            output.append(input.prefix(size))
            input = input.dropFirst(size)
            if input.starts(with: Data([13, 10])) {
                input = input.dropFirst(2)
            } else {
                return nil
            }
        }
        return nil
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw HTTPError.message("请求超时")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
