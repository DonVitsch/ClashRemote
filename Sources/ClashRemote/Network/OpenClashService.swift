import Foundation

struct DashboardSnapshot {
    var status = OpenClashStatus()
    var traffic = TrafficSnapshot()
    var configs: [ConfigFile] = []
    var subscriptions: [Subscription] = []
    var groups: [ProxyGroup] = []
    var rules: [ClashRule] = []
}

@MainActor
final class OpenClashService {
    private let client: OpenClashClient

    init(device: RouterDevice) {
        client = OpenClashClient(device: device)
    }

    func connect() async throws -> DashboardSnapshot {
        try await client.login()
        return try await refresh(full: true)
    }

    func refresh(full: Bool) async throws -> DashboardSnapshot {
        var snap = DashboardSnapshot()
        let status = try await client.luciGet("admin/services/openclash/status")
        let rule = (try? await client.luciGet("admin/services/openclash/rule_mode")) ?? [:]
        let run = (try? await client.luciGet("admin/services/openclash/get_run_mode")) ?? [:]
        let settings = (try? await client.luciGet("admin/services/openclash/oc_settings")) ?? [:]
        let files = (try? await client.luciGet("admin/services/openclash/config_file_list")) ?? [:]
        let uci = try await client.uciGet(config: "openclash")
        let traffic: [String: Any] = [:]
        let board: [String: Any]
        do {
            board = JSONValue.dict(try await client.ubus(object: "system", method: "board"))
        } catch {
            board = [:]
        }

        client.loadClashEndpoint(from: status, uci: uci)

        let config = uci["config"] ?? [:]
        var s = OpenClashStatus()
        s.running = JSONValue.bool(status["clash"])
        s.coreType = JSONValue.string(status["core_type"])
        s.dashboardHost = JSONValue.string(status["daip"])
        s.dashboardPort = client.clashPort
        s.dashboardSecret = client.clashSecret
        s.mixedPort = JSONValue.string(status["mixed_port"])
        if s.mixedPort.isEmpty { s.mixedPort = JSONValue.string(config["mixed_port"]) }
        s.ruleMode = RuleMode(rawValue: JSONValue.string(rule["mode"])) ?? .rule
        s.runMode = JSONValue.string(run["mode"])
        if s.runMode.isEmpty { s.runMode = JSONValue.string(config["en_mode"]) }
        s.respectRules = JSONValue.bool(settings["respect_rules"])
        s.metaSniffer = JSONValue.bool(settings["meta_sniffer"])
        s.oversea = JSONValue.bool(settings["oversea"])
        s.streamUnlock = JSONValue.bool(settings["stream_unlock"])
        s.chinaIPRoute = JSONValue.bool(config["china_ip_route"])
        s.enabled = JSONValue.bool(config["enable"])
        s.configPath = JSONValue.string(files["current_config"])
        if s.configPath.isEmpty { s.configPath = JSONValue.string(config["config_path"]) }
        s.hostname = JSONValue.string(board["hostname"])
        s.model = JSONValue.string(board["model"])
        snap.status = s

        var snapshotTraffic = TrafficSnapshot(
            up: JSONValue.string(traffic["up"]),
            down: JSONValue.string(traffic["down"]),
            upTotal: JSONValue.string(traffic["up_total"]),
            downTotal: JSONValue.string(traffic["down_total"]),
            connections: JSONValue.int(traffic["connections"]),
            cpu: JSONValue.string(traffic["cpu"]),
            mem: JSONValue.string(traffic["mem"])
        )
        if snapshotTraffic.connections == 0 && snapshotTraffic.downTotal.isEmpty {
            if let clashTraffic = try? await loadClashTraffic() {
                snapshotTraffic = clashTraffic
            }
        }
        snap.traffic = snapshotTraffic

        let currentName = s.configFileName
        var configs: [ConfigFile] = []
        for item in JSONValue.array(files["config_files"]) {
            let d = JSONValue.dict(item)
            let name = JSONValue.string(d["name"])
            configs.append(
                ConfigFile(
                    name: name,
                    path: JSONValue.string(d["path"]),
                    size: JSONValue.int(d["size"]),
                    current: name == currentName
                )
            )
        }
        if configs.isEmpty {
            for item in JSONValue.array(JSONValue.dict(try? await client.luciGet("admin/services/openclash/config_name"))["config_name"]) {
                let name = JSONValue.string(JSONValue.dict(item)["name"])
                if name.hasSuffix(".bak") { continue }
                configs.append(ConfigFile(name: name, path: "", size: 0, current: name == currentName))
            }
        }
        snap.configs = configs.sorted { $0.current && !$1.current }

        var subs: [Subscription] = []
        for (key, value) in uci {
            if JSONValue.string(value[".type"]) != "config_subscribe" { continue }
            subs.append(
                Subscription(
                    section: key,
                    name: JSONValue.string(value["name"]),
                    address: JSONValue.string(value["address"]),
                    enabled: JSONValue.bool(value["enabled"]),
                    userAgent: JSONValue.string(value["sub_ua"])
                )
            )
        }
        snap.subscriptions = subs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if full {
            snap.groups = (try? await loadGroups()) ?? []
            snap.rules = (try? await loadRules()) ?? []
        }
        return snap
    }

    func setRunning(_ running: Bool) async throws {
        _ = try await client.luciGet(
            "admin/services/openclash/action",
            query: ["action": running ? "start" : "stop"]
        )
    }

    func restart() async throws {
        _ = try await client.luciGet(
            "admin/services/openclash/action",
            query: ["action": "restart"]
        )
    }

    func setRuleMode(_ mode: RuleMode) async throws {
        do {
            _ = try await client.clashRequest(
                path: "/configs",
                method: "PATCH",
                json: ["mode": mode.rawValue]
            )
        } catch {
            // Clash API 不可用时走 LuCI
        }
        _ = try await client.luciGet(
            "admin/services/openclash/switch_rule_mode",
            query: ["rule_mode": mode.rawValue]
        )
    }

    func setCapture(_ capture: RunCapture) async throws {
        _ = try await client.luciGet(
            "admin/services/openclash/switch_run_mode",
            query: ["run_mode": capture.rawValue]
        )
    }

    func setOCSetting(_ name: String, value: Bool) async throws {
        _ = try await client.luciGet(
            "admin/services/openclash/switch_oc_setting",
            query: ["setting": name, "value": value ? "1" : "0"]
        )
    }

    func setChinaIPRoute(_ enabled: Bool) async throws {
        try await client.uciSet(
            config: "openclash",
            section: "config",
            values: ["china_ip_route": enabled ? "1" : "0"]
        )
        try await client.uciCommit(config: "openclash")
        try await restart()
    }

    func switchConfig(_ file: ConfigFile) async throws {
        let path = file.path.isEmpty ? file.name : file.path
        _ = try await client.luciGet(
            "admin/services/openclash/switch_config",
            query: ["config_file": path]
        )
    }

    func updateConfig(filename: String) async throws {
        let name = filename.hasSuffix(".yaml") ? filename : "\(filename).yaml"
        let result = try await client.luciGet(
            "admin/services/openclash/update_config",
            query: ["filename": name]
        )
        let status = JSONValue.string(result["status"])
        if !status.isEmpty && status != "success" {
            throw HTTPError.message(JSONValue.string(result["message"]).ifEmpty(JSONValue.string(result["error"]).ifEmpty("更新失败")))
        }
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws {
        let values: [String: Any] = [
            "name": sub.name,
            "address": sub.address,
            "enabled": sub.enabled ? "1" : "0",
            "sub_ua": sub.userAgent.isEmpty ? "clash.meta" : sub.userAgent,
            "sub_convert": "0"
        ]
        if isNew {
            _ = try await client.uciAdd(config: "openclash", type: "config_subscribe", values: values)
        } else {
            try await client.uciSet(config: "openclash", section: sub.section, values: values)
        }
        try await client.uciCommit(config: "openclash")
    }

    func deleteSubscription(_ sub: Subscription) async throws {
        try await client.uciDelete(config: "openclash", section: sub.section)
        try await client.uciCommit(config: "openclash")
    }

    func addSubscriptionViaLuCI(name: String, url: String) async throws {
        let result = try await client.luciGet(
            "admin/services/openclash/add_subscription",
            query: [
                "name": name,
                "address": url,
                "sub_ua": "clash.meta",
                "sub_convert": "0",
                "convert_address": "",
                "template": "",
                "emoji": "false",
                "udp": "false",
                "skip_cert_verify": "false",
                "sort": "false",
                "node_type": "false",
                "rule_provider": "false",
                "custom_params": "",
                "keyword": "",
                "ex_keyword": "",
                "de_ex_keyword": ""
            ]
        )
        let status = JSONValue.string(result["status"])
        if !status.isEmpty && status != "success" {
            throw HTTPError.message(JSONValue.string(result["message"]).ifEmpty("添加订阅失败"))
        }
        try await updateConfig(filename: name)
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        _ = try await client.clashRequest(
            path: "/proxies/\(encoded)",
            method: "PUT",
            json: ["name": name]
        )
    }

    func testDelay(name: String) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let response = try await client.clashRequest(
            path: "/proxies/\(encoded)/delay",
            query: [
                "timeout": "5000",
                "url": "http://www.gstatic.com/generate_204"
            ]
        )
        let dict = try response.jsonDict()
        return JSONValue.int(dict["delay"])
    }

    func loadClashTraffic() async throws -> TrafficSnapshot {
        let response = try await client.clashRequest(path: "/connections")
        let dict = try response.jsonDict()
        let up = JSONValue.int(dict["uploadTotal"])
        let down = JSONValue.int(dict["downloadTotal"])
        let conns = JSONValue.array(dict["connections"]).count
        return TrafficSnapshot(
            up: "",
            down: "",
            upTotal: ByteCountFormatter.string(fromByteCount: Int64(up), countStyle: .file),
            downTotal: ByteCountFormatter.string(fromByteCount: Int64(down), countStyle: .file),
            connections: conns,
            cpu: "",
            mem: ""
        )
    }

    func loadGroups() async throws -> [ProxyGroup] {
        let response = try await client.clashRequest(path: "/proxies")
        let dict = try response.jsonDict()
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
            let selectable = type == "Selector" || name == "GLOBAL"
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
                    selectable: selectable
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

    func loadRules() async throws -> [ClashRule] {
        let response = try await client.clashRequest(path: "/rules")
        let dict = try response.jsonDict()
        var rules: [ClashRule] = []
        for item in JSONValue.array(dict["rules"]) {
            let d = JSONValue.dict(item)
            rules.append(
                ClashRule(
                    type: JSONValue.string(d["type"]),
                    payload: JSONValue.string(d["payload"]),
                    proxy: JSONValue.string(d["proxy"])
                )
            )
        }
        return rules
    }

    func addDirectRule(domain: String, proxy: String, configPath: String) async throws {
        let host = sanitizeDomain(domain)
        guard !host.isEmpty else { throw HTTPError.message("域名无效") }
        let type = host.contains("*") || host.contains("/") ? "DOMAIN-KEYWORD" : "DOMAIN-SUFFIX"
        let payload = host.replacingOccurrences(of: "*.", with: "")
        let line = "- \(type),\(payload),\(proxy)"

        let path = configPath
        let read = try await client.luciGet(
            "admin/services/openclash/config_file_read",
            query: ["config_file": path]
        )
        var content = JSONValue.string(read["content"])
        if content.isEmpty { throw HTTPError.message("读不到配置文件") }
        if content.contains("\(type),\(payload),") {
            throw HTTPError.message("规则已存在")
        }
        if let range = content.range(of: "\nrules:")
            ?? content.range(of: "\nrules :")
            ?? content.range(of: "rules:\n") {
            let afterHeader = range.upperBound
            if content[afterHeader...].hasPrefix("\n") {
                content.insert(contentsOf: "\(line)\n", at: content.index(after: afterHeader))
            } else {
                content.insert(contentsOf: "\n\(line)\n", at: afterHeader)
            }
        } else {
            content += "\nrules:\n\(line)\n"
        }
        let save = try await client.luciPostForm(
            "admin/services/openclash/config_file_save",
            fields: ["config_file": path, "content": content]
        )
        let status = JSONValue.string(save["status"])
        if !status.isEmpty && status != "success" {
            throw HTTPError.message(JSONValue.string(save["message"]).ifEmpty("保存规则失败"))
        }
        try await restart()
    }

    func closeConnections() async throws {
        _ = try await client.luciGet("admin/services/openclash/close_all_connection")
        _ = try? await client.clashRequest(path: "/connections", method: "DELETE")
    }

    private func sanitizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "")
        s = s.replacingOccurrences(of: "http://", with: "")
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
