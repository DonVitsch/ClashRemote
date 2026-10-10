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
    private var currentConfigFile = ""

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
        currentConfigFile = s.configFileName
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

        // 组列表较轻（Clash /proxies），每次刷新都拉，便于「当前节点」实时更新
        snap.groups = (try? await loadGroups()) ?? []
        if full {
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
        var candidates: [String] = []
        func addCandidate(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) { candidates.append(trimmed) }
            if !trimmed.hasSuffix(".yaml") && !trimmed.hasSuffix(".yml") {
                let withExt = "\(trimmed).yaml"
                if !candidates.contains(withExt) { candidates.append(withExt) }
            }
        }
        addCandidate(filename)
        addCandidate(currentConfigFile)

        var lastError: Error = HTTPError.message("更新订阅失败")
        for name in candidates {
            do {
                let result = try await client.luciGet(
                    "admin/services/openclash/update_config",
                    query: ["filename": name],
                    timeout: 180
                )
                let status = JSONValue.string(result["status"])
                if status == "start" || status == "updating" {
                    try await Task.sleep(for: .seconds(8))
                    return
                }
                if !status.isEmpty && status != "success" {
                    lastError = HTTPError.message(
                        JSONValue.string(result["message"])
                            .ifEmpty(JSONValue.string(result["error"]).ifEmpty("更新失败"))
                    )
                    continue
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws {
        let name = sub.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = sub.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError.message("订阅名称不能为空") }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw HTTPError.message("订阅链接需要 http/https")
        }

        if isNew {
            do {
                try await addSubscriptionViaLuCI(name: name, url: url, userAgent: sub.userAgent)
            } catch {
                let values: [String: Any] = [
                    "name": name,
                    "address": url,
                    "enabled": sub.enabled ? "1" : "0",
                    "sub_ua": sub.userAgent.isEmpty ? "clash.meta" : sub.userAgent,
                    "sub_convert": "0"
                ]
                _ = try await client.uciAdd(config: "openclash", type: "config_subscribe", values: values)
                try await client.uciCommit(config: "openclash")
            }
        } else {
            let values: [String: Any] = [
                "name": name,
                "address": url,
                "enabled": sub.enabled ? "1" : "0",
                "sub_ua": sub.userAgent.isEmpty ? "clash.meta" : sub.userAgent,
                "sub_convert": "0"
            ]
            try await client.uciSet(config: "openclash", section: sub.section, values: values)
            try await client.uciCommit(config: "openclash")
        }
        try await updateConfig(filename: name)
    }

    func deleteSubscription(_ sub: Subscription) async throws {
        try await client.uciDelete(config: "openclash", section: sub.section)
        try await client.uciCommit(config: "openclash")
    }

    func addSubscriptionViaLuCI(name: String, url: String, userAgent: String = "clash.meta") async throws {
        let fields = [
            "name": name,
            "address": url,
            "sub_ua": userAgent.isEmpty ? "clash.meta" : userAgent,
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
        let result: [String: Any]
        do {
            result = try await client.luciPostForm(
                "admin/services/openclash/add_subscription",
                fields: fields,
                timeout: 60
            )
        } catch {
            result = try await client.luciGet(
                "admin/services/openclash/add_subscription",
                query: fields,
                timeout: 60
            )
        }
        let status = JSONValue.string(result["status"])
        if !status.isEmpty && status != "success" {
            throw HTTPError.message(JSONValue.string(result["message"]).ifEmpty("添加订阅失败"))
        }
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        _ = try await client.clashRequest(
            path: "/proxies/\(encoded)",
            method: "PUT",
            json: ["name": name]
        )
    }

    func testDelay(name: String, timeoutMs: Int) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let bounded = min(max(timeoutMs, 500), 15_000)
        let response = try await client.clashRequest(
            path: "/proxies/\(encoded)/delay",
            query: [
                "timeout": "\(bounded)",
                "url": "http://www.gstatic.com/generate_204"
            ],
            timeout: Double(bounded) / 1000 + 3
        )
        let dict = try response.jsonDict()
        return JSONValue.int(dict["delay"])
    }

    func testGroupDelay(group: String, timeoutMs: Int) async throws -> [String: Int] {
        try await ClashDelayProbe.groupDelay(
            group: group,
            timeoutMs: timeoutMs
        ) { path, query, timeout in
            try await client.clashRequest(path: path, query: query, timeout: timeout)
        }
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
            let selectable = ProxyGroup.allowsManualSelect(type: type, name: name)
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

    func flattenPolicyGroups(configPath: String, nodeFilter: String? = nil) async throws {
        try await mutateConfig(configPath) { SimplePolicyYAML.rewrite($0, nodeFilter: nodeFilter) }
    }

    func addDirectRule(domain: String, proxy: String, configPath: String) async throws {
        let host = sanitizeDomain(domain)
        guard !host.isEmpty else { throw HTTPError.message("域名无效") }
        let type = host.contains("*") || host.contains("/") ? "DOMAIN-KEYWORD" : "DOMAIN-SUFFIX"
        let payload = host.replacingOccurrences(of: "*.", with: "")
        let line = "- \(type),\(payload),\(proxy)"
        try await mutateConfig(configPath) { raw in
            if raw.contains("\(type),\(payload),") {
                throw HTTPError.message("规则已存在")
            }
            return try DomainRulePolicy.insertRuleLine(raw, line: line)
        }
    }

    func upsertProfileRule(_ rule: LocalDomainRule, configPath: String) async throws {
        try await mutateConfig(configPath) { try DomainRulePolicy.upsertRuleLine($0, rule: rule) }
    }

    private func mutateConfig(_ path: String, _ mutate: (String) throws -> String) async throws {
        let content = try await readConfigFile(path)
        let next = try mutate(content)
        if next == content { return }
        try await saveConfigFile(path, content: next)
        try await restart()
    }

    private func readConfigFile(_ path: String) async throws -> String {
        let read = try await client.luciGet(
            "admin/services/openclash/config_file_read",
            query: ["config_file": path],
            timeout: 60
        )
        let content = JSONValue.string(read["content"])
        if content.isEmpty { throw HTTPError.message("读不到配置文件") }
        return content
    }

    private func saveConfigFile(_ path: String, content: String) async throws {
        let save = try await client.luciPostForm(
            "admin/services/openclash/config_file_save",
            fields: ["config_file": path, "content": content],
            timeout: 60
        )
        let status = JSONValue.string(save["status"])
        if !status.isEmpty && status != "success" {
            throw HTTPError.message(JSONValue.string(save["message"]).ifEmpty("保存配置失败"))
        }
    }

    func closeConnections() async throws {
        _ = try await client.luciGet("admin/services/openclash/close_all_connection")
        _ = try? await client.clashRequest(path: "/connections", method: "DELETE")
    }

    func installDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        try await writeFailoverOverwrite(interval: interval, enabled: enabled, profile: profile)
        try await writeRouterFile(OpenClashFailover.path, contents: OpenClashFailover.source)
        try await writeRouterFile(OpenClashFailover.initPath, contents: OpenClashFailover.initScript)
        try await writeRouterFile(
            OpenClashFailover.confPath,
            contents: OpenClashFailover.conf(
                secret: client.clashSecret, port: client.clashPort,
                interval: interval, enabled: enabled, profile: profile
            )
        )
        if (try? await client.fileExec(OpenClashFailover.startCommand))?.lowercased().contains("started") == true {
            return
        }
        _ = try await client.luciGet(
            "admin/services/openclash/action",
            query: ["action": "restart"],
            timeout: 120
        )
    }

    func uninstallDeviceFailover() async throws {
        let current = (try? await readConfigFile(OpenClashFailover.overwritePath)) ?? ""
        if OpenClashFailover.hookInstalled(in: current) {
            try await saveConfigFile(
                OpenClashFailover.overwritePath,
                content: OpenClashFailover.stripHook(current)
            )
        }
        _ = try? await client.fileExec(
            """
            /etc/init.d/clashremote-failover stop >/dev/null 2>&1
            /etc/init.d/clashremote-failover disable >/dev/null 2>&1
            \(OpenClashFailover.path) stop >/dev/null 2>&1
            rm -f \(OpenClashFailover.path) \(OpenClashFailover.confPath) \(OpenClashFailover.pidPath) \(OpenClashFailover.statusPath) \(OpenClashFailover.initPath) \(OpenClashFailover.pinPath)
            """
        )
    }

    func updateDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        try await writeFailoverOverwrite(interval: interval, enabled: enabled, profile: profile)
        try await writeRouterFile(
            OpenClashFailover.confPath,
            contents: OpenClashFailover.conf(
                secret: client.clashSecret, port: client.clashPort,
                interval: interval, enabled: enabled, profile: profile
            )
        )
    }

    func deviceFailoverStatus() async throws -> DeviceFailoverStatus {
        if let dump = try? await client.fileExec(
            """
            echo INSTALLED=$(test -f \(OpenClashFailover.path) && echo yes || echo no)
            echo HOOKED=$(ls /etc/rc.d/S*clashremote-failover >/dev/null 2>&1 && echo yes || echo no)
            if [ -f \(OpenClashFailover.pidPath) ]; then pid=$(cat \(OpenClashFailover.pidPath)); [ -d /proc/$pid ] && echo RUNNING=yes || echo RUNNING=no; else echo RUNNING=no; fi
            echo '---CONF---'
            cat \(OpenClashFailover.confPath) 2>/dev/null
            echo '---STATUS---'
            cat \(OpenClashFailover.statusPath) 2>/dev/null
            echo '---LOG---'
            tail -n 12 \(OpenClashFailover.logPath) 2>/dev/null
            """
        ), dump.contains("INSTALLED=") {
            return NodeFailoverScript.parseStatusDump(dump)
        }
        let overwrite = (try? await readConfigFile(OpenClashFailover.overwritePath)) ?? ""
        var status = DeviceFailoverStatus()
        status.installed = OpenClashFailover.hookInstalled(in: overwrite)
        status.hooked = status.installed
        status.running = false
        status.enabled = true
        status.interval = 5
        if status.installed {
            status.detail = "已写入启动脚本，但路由器未返回运行状态"
        }
        status.updatedAt = Date()
        return status
    }

    func runDeviceFailoverOnce() async throws {
        let out = try await client.fileExec("\(OpenClashFailover.path) once")
        if out.isEmpty {
            throw HTTPError.message("路由器不允许远程执行命令，等 OpenClash 自己启动守护后再测")
        }
    }

    func deviceFailoverHistory() async throws -> [FailoverEvent] {
        let raw = (try? await client.fileExec("tail -n 80 \(OpenClashFailover.historyPath) 2>/dev/null")) ?? ""
        return NodeFailoverScript.parseHistory(raw)
    }

    private func writeFailoverOverwrite(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        let current = (try? await readConfigFile(OpenClashFailover.overwritePath)) ?? ""
        let next = OpenClashFailover.mergeOverwrite(current, interval: interval, enabled: enabled, profile: profile)
        try await saveConfigFile(OpenClashFailover.overwritePath, content: next)
    }

    private func writeRouterFile(_ path: String, contents: String) async throws {
        do {
            try await client.fileWrite(path, contents: contents)
        } catch {
            let b64 = Data(contents.utf8).base64EncodedString()
            let written = try await client.fileExec(
                """
                mkdir -p "$(dirname '\(path)')"
                echo '\(b64)' | base64 -d > '\(path)'
                echo ok
                """
            )
            if !written.contains("ok") {
                throw HTTPError.message("写不进路由器：\(error.localizedDescription)")
            }
        }
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

enum SimplePolicyYAML {
    static let groupName = "节点选择"
    private static let legacyAppleMarkerBegin = "# ClashRemote: AppleIntelligence"
    private static let legacyAppleMarkerEnd = "# ClashRemote: AppleIntelligence end"
    private static let legacyAppleGroupName = "Apple Intelligence"
    static let defaultNodeExcludeFilter = LocalProfile.default.nodeExcludeRegex()

    static func rewrite(_ raw: String, nodeFilter: String? = nil) -> String {
        let exclude = nodeFilter ?? defaultNodeExcludeFilter
        let providers = providerNames(in: raw)
        guard !providers.isEmpty else { return raw }

        let useLines = providers.map { "      - \($0)" }.joined(separator: "\n")
        let excludeLine: String
        if exclude.isEmpty {
            excludeLine = ""
        } else {
            let encoded = (try? JSONEncoder().encode(exclude)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            excludeLine = "\n    exclude-filter: \(encoded)"
        }
        let groupsBlock = """
        proxy-groups:
          - name: \(groupName)
            type: select
            use:
        \(useLines)
            filter: .*\(excludeLine)
        """

        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = replaceTopLevelBlock(lines, header: "GW:", with: [])
        lines = replaceTopLevelBlock(lines, header: "proxy-groups:", with: groupsBlock.split(separator: "\n").map(String.init))
        lines = rewriteRuleLines(lines)
        var text = lines.joined(separator: "\n")
        if raw.hasSuffix("\n"), !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func rewriteRuleLines(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { isTopLevel($0, header: "rules:") }) else { return lines }
        let end = (start + 1 ..< lines.count).first { isTopLevelKey(lines[$0]) } ?? lines.count
        var out = Array(lines[..<start])
        out.append("rules:")
        out.append(contentsOf: DomesticDirectPolicy.ruleLines())
        let senplayerBegin = "# ClashRemote: Senplayer"
        let senplayerEnd = "# ClashRemote: Senplayer end"
        var skippingMarked = false
        for i in (start + 1)..<end {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(legacyAppleMarkerBegin)
                || trimmed.contains(senplayerBegin)
                || trimmed.contains(DomesticDirectPolicy.markerBegin) {
                skippingMarked = true
                continue
            }
            if skippingMarked {
                if trimmed.contains(legacyAppleMarkerEnd)
                    || trimmed.contains(senplayerEnd)
                    || trimmed.contains(DomesticDirectPolicy.markerEnd) {
                    skippingMarked = false
                }
                continue
            }
            if trimmed.contains(",\(legacyAppleGroupName)") { continue }
            if trimmed.contains(",Senplayer") { continue }
            if trimmed.contains("RULE-SET,Spotify") { continue }
            if trimmed.hasPrefix("- MATCH,") || trimmed.hasPrefix("MATCH,") {
                out.append("  - MATCH,\(groupName)")
                continue
            }
            out.append(DomesticDirectPolicy.rewriteLegacyDomesticTarget(line))
        }
        if end < lines.count {
            out.append(contentsOf: lines[end...])
        }
        return out
    }

    private static func replaceTopLevelBlock(_ lines: [String], header: String, with replacement: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { isTopLevel($0, header: header) }) else { return lines }
        let end = (start + 1 ..< lines.count).first { isTopLevelKey(lines[$0]) } ?? lines.count
        var out = Array(lines[..<start])
        out.append(contentsOf: replacement)
        if end < lines.count {
            out.append(contentsOf: lines[end...])
        }
        return out
    }

    static func providerNames(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { isTopLevel($0, header: "proxy-providers:") }) else { return [] }
        let end = (start + 1 ..< lines.count).first { isTopLevelKey(lines[$0]) } ?? lines.count
        var names: [String] = []
        for i in (start + 1)..<end {
            let line = lines[i]
            guard line.hasPrefix("  "), !line.hasPrefix("    ") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasSuffix(":") else { continue }
            names.append(String(trimmed.dropLast()))
        }
        return names
    }

    static func isTopLevel(_ line: String, header: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasPrefix(header)
    }

    static func isTopLevelKey(_ line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("#") { return false }
        return line.contains(":")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
