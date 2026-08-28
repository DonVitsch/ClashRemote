import Foundation

/// 猫猫（UFI-TOOLS 上的 Mihomo TProxy）。运行时走 Clash API :7788，订阅走 UFI root shell。
@MainActor
final class MaoMaoService: ClashBackend {
    private let device: RouterDevice
    private let http = HTTPClient()
    private let ufi: UFIClient
    private var clashPort = 7788
    private var clashSecret = "123456"
    private let configPath = "/data/clash/Proxy/config.yaml"
    private let servicePath = "/data/clash/Scripts/Clash.Service"

    init(device: RouterDevice) {
        self.device = device
        clashPort = device.plugin.defaultClashPort
        ufi = UFIClient(device: device)
    }

    func connect() async throws -> DashboardSnapshot {
        try await discoverSecret()
        return try await refresh(full: true)
    }

    func refresh(full: Bool) async throws -> DashboardSnapshot {
        var snap = DashboardSnapshot()
        let configs = try await clashJSON("/configs")
        let version = (try? await clashJSON("/version")) ?? [:]

        var status = OpenClashStatus()
        status.running = true
        status.coreType = JSONValue.bool(version["meta"]) ? "Meta" : "Clash"
        status.dashboardHost = device.host
        status.dashboardPort = clashPort
        status.dashboardSecret = clashSecret
        status.mixedPort = JSONValue.string(configs["mixed-port"])
        status.ruleMode = RuleMode(rawValue: JSONValue.string(configs["mode"]).lowercased()) ?? .rule
        let tunOn = JSONValue.bool(JSONValue.dict(configs["tun"])["enable"])
        status.runMode = tunOn ? "tproxy-tun" : "tproxy"
        status.metaSniffer = JSONValue.bool(configs["sniffing"])
        status.model = device.name
        status.hostname = device.host
        status.configPath = "config.yaml"
        status.enabled = true
        snap.status = status

        if let traffic = try? await loadTraffic() {
            snap.traffic = traffic
        }
        snap.configs = [
            ConfigFile(name: "config.yaml", path: configPath, size: 0, current: true)
        ]
        snap.subscriptions = (try? await loadSubscriptions()) ?? []
        if full {
            snap.groups = (try? await loadGroups()) ?? []
            snap.rules = (try? await loadRules()) ?? []
        }
        return snap
    }

    func setRunning(_ running: Bool) async throws {
        let action = running ? "start" : "stop"
        _ = try await ufi.rootShell("\(servicePath) \(action)", timeoutMS: 30_000)
    }

    func restart() async throws {
        _ = try await ufi.rootShell(
            "\(servicePath) stop; sleep 1; \(servicePath) start",
            timeoutMS: 40_000
        )
    }

    func setRuleMode(_ mode: RuleMode) async throws {
        _ = try await clashRequest("/configs", method: "PATCH", json: ["mode": mode.rawValue])
    }

    func setCapture(_ capture: RunCapture) async throws {
        let tunOn = capture != .enhance
        _ = try await clashRequest(
            "/configs",
            method: "PATCH",
            json: ["tun": ["enable": tunOn]]
        )
    }

    func setOCSetting(_ name: String, value: Bool) async throws {
        if name == "meta_sniffer" {
            _ = try await clashRequest("/configs", method: "PATCH", json: ["sniffing": value])
            return
        }
        throw HTTPError.message("这个开关是 OpenClash 专用的，猫猫上没有。")
    }

    func setChinaIPRoute(_ enabled: Bool) async throws {
        throw HTTPError.message("绕过大陆是 OpenClash 的 UCI 项。猫猫请改配置文件里的规则。")
    }

    func switchConfig(_ file: ConfigFile) async throws {
        throw HTTPError.message("猫猫目前只有一份 /data/clash/Proxy/config.yaml")
    }

    func updateConfig(filename: String) async throws {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "config.yaml" {
            try await restart()
            return
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        do {
            _ = try await clashRequest("/providers/proxies/\(encoded)", method: "PUT")
        } catch {
            try await restart()
        }
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws {
        let name = sanitizeProviderName(sub.name)
        let url = sub.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError.message("订阅名称不能为空") }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw HTTPError.message("订阅链接需要 http/https")
        }
        var yaml = try await ufi.readFile(configPath)
        if isNew {
            yaml = try insertProvider(named: name, url: url, into: yaml)
        } else {
            let oldName = sanitizeProviderName(sub.section.isEmpty ? sub.name : sub.section)
            yaml = try updateProvider(named: oldName, newName: name, url: url, in: yaml)
        }
        try await writeConfigAndRestart(yaml)
    }

    func deleteSubscription(_ sub: Subscription) async throws {
        let name = sanitizeProviderName(sub.section.isEmpty ? sub.name : sub.section)
        guard !name.isEmpty else { throw HTTPError.message("订阅名称无效") }
        let yaml = try await ufi.readFile(configPath)
        let next = try removeProvider(named: name, from: yaml)
        try await writeConfigAndRestart(next)
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        _ = try await clashRequest("/proxies/\(encoded)", method: "PUT", json: ["name": name])
    }

    func testDelay(name: String) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let dict = try await clashJSON(
            "/proxies/\(encoded)/delay",
            query: ["timeout": "5000", "url": "http://www.gstatic.com/generate_204"]
        )
        return JSONValue.int(dict["delay"])
    }

    func addDirectRule(domain: String, proxy: String, configPath: String) async throws {
        throw HTTPError.message("猫猫暂不改配置文件。规则请在 7788 面板或插件 YAML 里写。")
    }

    func closeConnections() async throws {
        _ = try await clashRequest("/connections", method: "DELETE")
    }

    private func discoverSecret() async throws {
        let candidates = [clashSecret, "123456", device.password, "admin", ""]
        var unique: [String] = []
        for item in candidates where !unique.contains(item) {
            unique.append(item)
        }
        var lastError: Error = HTTPError.message("连不上猫猫面板 \(device.host):\(clashPort)")
        for secret in unique {
            clashSecret = secret
            do {
                _ = try await clashJSON("/version")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func loadSubscriptions() async throws -> [Subscription] {
        let yaml = try await ufi.readFile(configPath)
        return parseProviders(yaml).map { item in
            Subscription(
                section: item.name,
                name: item.name,
                address: item.url,
                enabled: true,
                userAgent: ""
            )
        }
    }

    private func writeConfigAndRestart(_ yaml: String) async throws {
        try await ufi.writeFile(configPath, contents: yaml)
        try await restart()
    }

    private func parseProviders(_ yaml: String) -> [(name: String, url: String)] {
        guard let section = providerSection(yaml) else { return [] }
        var headers: [(name: String, start: String.Index)] = []
        let headerRe = try? NSRegularExpression(pattern: #"(?m)^    ([^ \n][^:\n]*):"#)
        let ns = NSRange(section.startIndex..<section.endIndex, in: section)
        headerRe?.enumerateMatches(in: section, range: ns) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: section) else { return }
            headers.append((String(section[nameRange]), nameRange.lowerBound))
        }
        var result: [(String, String)] = []
        for (i, header) in headers.enumerated() {
            let end = i + 1 < headers.count ? headers[i + 1].start : section.endIndex
            let block = String(section[header.start..<end])
            guard block.contains("type: http"), let url = urlLine(in: block) else { continue }
            result.append((header.name, url))
        }
        return result
    }

    private func providerSection(_ yaml: String) -> String? {
        guard let start = yaml.range(of: "\nproxy-providers:\n") ?? yaml.range(of: "proxy-providers:\n") else {
            return nil
        }
        let after = yaml[start.upperBound...]
        let endKeys = ["\nrule-anchor:", "\nrule-providers:", "\nrules:", "\nsecret:"]
        var end = yaml.endIndex
        for key in endKeys {
            if let r = after.range(of: key) {
                let idx = r.lowerBound
                if idx < end { end = idx }
            }
        }
        return String(yaml[start.upperBound..<end])
    }

    private func urlLine(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("        url:") && !line.hasPrefix("            url:") {
                return String(line.dropFirst("        url:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private func insertProvider(named name: String, url: String, into yaml: String) throws -> String {
        let existing = parseProviders(yaml).map(\.name)
        if existing.contains(name) {
            return try updateProvider(named: name, newName: name, url: url, in: yaml)
        }
        let index = String(format: "%02d", existing.count + 1)
        let block = providerBlock(name: name, url: url, index: index)
        var next = yaml
        if let range = next.range(of: "\nrule-anchor:") ?? next.range(of: "\nrule-providers:") {
            next.insert(contentsOf: block, at: range.lowerBound)
        } else if next.contains("proxy-providers:") {
            next += block
        } else {
            next += "\nproxy-providers:\n" + block
        }
        return addProviderToUseLists(name, in: next)
    }

    private func updateProvider(named oldName: String, newName: String, url: String, in yaml: String) throws -> String {
        var next = yaml
        if oldName != newName {
            next = next.replacingOccurrences(of: "        - \(oldName)", with: "        - \(newName)")
            next = next.replacingOccurrences(of: "    \(oldName):", with: "    \(newName):")
            next = next.replacingOccurrences(of: "./proxies/\(oldName).yaml", with: "./proxies/\(newName).yaml")
        }
        guard let blockRange = providerBlockRange(named: newName, in: next) else {
            throw HTTPError.message("找不到订阅 \(oldName)")
        }
        let block = String(next[blockRange])
        var updated = block
        if let urlRange = updated.range(of: #"(?m)^        url: .+$"#, options: .regularExpression) {
            updated.replaceSubrange(urlRange, with: "        url: \(url)")
        } else {
            throw HTTPError.message("订阅块没有 url 字段")
        }
        next.replaceSubrange(blockRange, with: updated)
        return next
    }

    private func removeProvider(named name: String, from yaml: String) throws -> String {
        guard let blockRange = providerBlockRange(named: name, in: yaml) else {
            throw HTTPError.message("找不到订阅 \(name)")
        }
        var next = yaml
        next.removeSubrange(blockRange)
        if next.hasSuffix("\n\n\n") {
            next = String(next.dropLast())
        }
        next = next.replacingOccurrences(of: "\n        - \(name)", with: "")
        return next
    }

    private func providerBlockRange(named name: String, in yaml: String) -> Range<String.Index>? {
        let header = "    \(name):\n"
        guard let start = yaml.range(of: header) else { return nil }
        var idx = start.upperBound
        while idx < yaml.endIndex {
            let rest = yaml[idx...]
            guard let lineEnd = rest.firstIndex(of: "\n") else {
                return start.lowerBound..<yaml.endIndex
            }
            let line = yaml[idx...lineEnd]
            let isIndentedField = line.hasPrefix("        ") || line == "\n"
            if !isIndentedField && line != "\n" {
                return start.lowerBound..<idx
            }
            if line.hasPrefix("    ") && !line.hasPrefix("        ") && idx != start.upperBound {
                return start.lowerBound..<idx
            }
            idx = yaml.index(after: lineEnd)
        }
        return start.lowerBound..<yaml.endIndex
    }

    private func addProviderToUseLists(_ name: String, in yaml: String) -> String {
        let needle = "        - \(name)\n"
        if yaml.contains(needle) { return yaml }
        var next = yaml
        let pattern = #"(?m)( {4,6}use:\n(?:        - .+\n)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        let ns = NSRange(next.startIndex..<next.endIndex, in: next)
        let matches = regex.matches(in: next, range: ns).reversed()
        for match in matches {
            guard let range = Range(match.range, in: next) else { continue }
            var block = String(next[range])
            if !block.contains("        - \(name)\n") {
                if !block.hasSuffix("\n") { block += "\n" }
                block += "        - \(name)\n"
                next.replaceSubrange(range, with: block)
            }
        }
        return next
    }

    private func providerBlock(name: String, url: String, index: String) -> String {
        """
            \(name):
                health-check:
                    enable: true
                    interval: 600
                    lazy: false
                    timeout: 3000
                    tolerance: 100
                    url: https://www.gstatic.com/generate_204
                interval: 86400
                override:
                    additional-prefix: '[\(index)]'
                path: ./proxies/\(name).yaml
                type: http
                url: \(url)

        """
    }

    private func sanitizeProviderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
            if ch.unicodeScalars.allSatisfy({ $0.value > 127 }) { return ch }
            return "_"
        }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return name.isEmpty ? "机场" : name
    }

    private func loadTraffic() async throws -> TrafficSnapshot {
        let dict = try await clashJSON("/connections")
        let up = JSONValue.int(dict["uploadTotal"])
        let down = JSONValue.int(dict["downloadTotal"])
        return TrafficSnapshot(
            up: "",
            down: "",
            upTotal: ByteCountFormatter.string(fromByteCount: Int64(up), countStyle: .file),
            downTotal: ByteCountFormatter.string(fromByteCount: Int64(down), countStyle: .file),
            connections: JSONValue.array(dict["connections"]).count,
            cpu: "",
            mem: ""
        )
    }

    private func loadGroups() async throws -> [ProxyGroup] {
        let dict = try await clashJSON("/proxies")
        let proxies = JSONValue.dict(dict["proxies"])
        func proxyItem(named name: String) -> ProxyItem {
            let p = JSONValue.dict(proxies[name])
            let history = JSONValue.array(p["history"])
            var lastDelay: Int?
            if let last = history.last {
                let delay = JSONValue.int(JSONValue.dict(last)["delay"])
                lastDelay = delay == 0 ? -1 : delay
            }
            return ProxyItem(
                name: name,
                type: JSONValue.string(p["type"]).ifEmpty("Unknown"),
                lastDelay: lastDelay,
                ownerGroup: ""
            )
        }
        var groups: [ProxyGroup] = []
        for (name, value) in proxies {
            let p = JSONValue.dict(value)
            let type = JSONValue.string(p["type"])
            let options = (p["all"] as? [String]) ?? []
            guard !options.isEmpty else { continue }
            groups.append(
                ProxyGroup(
                    name: name,
                    type: type,
                    now: JSONValue.string(p["now"]),
                    nodes: options.map { node in
                        var item = proxyItem(named: node)
                        item.ownerGroup = name
                        return item
                    },
                    selectable: type == "Selector" || name == "GLOBAL"
                )
            )
        }
        return groups.sorted { a, b in
            if a.name == "GLOBAL" { return true }
            if b.name == "GLOBAL" { return false }
            if a.selectable != b.selectable { return a.selectable }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func loadRules() async throws -> [ClashRule] {
        let dict = try await clashJSON("/rules")
        return JSONValue.array(dict["rules"]).map { item in
            let d = JSONValue.dict(item)
            return ClashRule(
                type: JSONValue.string(d["type"]),
                payload: JSONValue.string(d["payload"]),
                proxy: JSONValue.string(d["proxy"])
            )
        }
    }

    private func clashJSON(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        json: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let response = try await clashRequest(path, method: method, query: query, json: json)
        if response.data.isEmpty { return [:] }
        return try response.jsonDict()
    }

    private func clashRequest(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        json: [String: Any]? = nil
    ) async throws -> HTTPResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = device.host
        components.port = clashPort
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw HTTPError.badURL }
        var headers = ["Authorization": "Bearer \(clashSecret)"]
        var body: Data?
        if let json {
            headers["Content-Type"] = "application/json"
            body = try JSONSerialization.data(withJSONObject: json)
        }
        let response = try await http.request(url: url, method: method, headers: headers, body: body)
        if response.status >= 400 {
            throw HTTPError.httpStatus(response.status, response.text)
        }
        return response
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
