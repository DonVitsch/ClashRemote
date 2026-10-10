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
        do {
            try await discoverSecret()
        } catch {
            // Clash API 不通，最常见的原因是猫猫核心没在跑（重启后没起来、配置有问题等）。
            // 猫猫的启停走 UFI root shell，不依赖 Clash API，所以这里可以直接自愈。
            let startOutput = (try? await ufi.rootShell(
                "\(servicePath) start",
                timeoutMS: 60_000
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? await Task.sleep(for: .seconds(4))
            do {
                try await discoverSecret()
            } catch {
                // 核心确实起不来：把路由器自己的报错原样带出来，别只丢一句含糊的"连不上"。
                let detail = startOutput.isEmpty ? error.localizedDescription : startOutput
                throw HTTPError.message("猫猫核心没有运行，自动启动也没成功：\(detail)")
            }
        }
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
        // 订阅列表要读 config.yaml，而猫猫是走 UFI root shell 读的（md5 + cat 两个来回）。
        // 3 秒一次的轮询完全不需要它 —— 只在 full 刷新时拉，否则就是白占路由器。
        if full {
            snap.subscriptions = (try? await loadSubscriptions()) ?? []
        }
        // 组列表较轻（Clash /proxies），每次刷新都拉，便于「当前节点」实时更新
        snap.groups = (try? await loadGroups()) ?? []
        if full {
            snap.rules = (try? await loadRules()) ?? []
        }
        return snap
    }

    func setRunning(_ running: Bool) async throws {
        let action = running ? "start" : "stop"
        _ = try await ufi.rootShell("\(servicePath) \(action)", timeoutMS: 30_000)
    }

    func restart() async throws {
        // ⚠️ clashctl 只认 start|stop 两个参数，传 restart 会被直接拒绝；
        // 而且拒绝是静默的（退出码非 0，输出没人看），会导致"配置写了但核心没重启"。
        // 启动这一步可能要重下订阅，所以超时给足。
        _ = try await ufi.rootShell(
            "\(servicePath) stop; sleep 1; \(servicePath) start",
            timeoutMS: 180_000
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
        let yaml = try await ufi.readFile(configPath)
        let providers = parseProviders(yaml)
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = providers.first { $0.name == name || name.hasPrefix($0.name) } ?? providers.first
        if let target {
            let encoded = target.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.name
            do {
                _ = try await clashRequest("/providers/proxies/\(encoded)", method: "PUT")
                return
            } catch {
                try await downloadSubscription(url: target.url, into: configPath)
                try await restart()
                return
            }
        }
        try await restart()
    }

    /// 猫猫最多支持 3 个订阅（插件自己的「订阅链接」弹窗就是 3 个输入框）。
    static let maxSubscriptions = 3

    /// 猫猫的策略组由插件生成、按用途分好，但节点来源都是 provider，
    /// 所以可以安全地收成一个「节点选择」组（见 MaoMaoPolicyYAML）。
    var needsGroupFlattening: Bool { true }

    /// 猫猫的订阅不能往 YAML 里插 `proxy-providers`。
    /// 插件自己的做法是把一份**两行清单**写进 config.yaml：
    ///   第 1 行：订阅 URL（空格分隔）
    ///   第 2 行：对应的 provider 名
    /// 然后由 clashctl 读清单 → 下载 `proxies/providerN.yaml` → 展开成完整的 proxy-providers 配置。
    /// 写 YAML 的话 clashctl 会报「空文件」并且核心直接起不来（之前就是这么把猫猫弄挂的）。
    func applySubscriptions(_ subs: [LocalSubscription], existing: [Subscription]) async throws {
        guard !subs.isEmpty else { throw HTTPError.message("本地配置里没有启用的订阅") }
        guard subs.count <= Self.maxSubscriptions else {
            throw HTTPError.message("猫猫最多只支持 \(Self.maxSubscriptions) 个订阅，本地有 \(subs.count) 个，请先在本地配置里停用多余的。")
        }
        let urls = subs.map { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard urls.allSatisfy({ $0.hasPrefix("http://") || $0.hasPrefix("https://") }) else {
            throw HTTPError.message("订阅链接需要以 http/https 开头")
        }
        let names = (1...urls.count).map { "provider\($0)" }
        let manifest = urls.joined(separator: " ") + "\n" + names.joined(separator: " ") + "\n"

        // 先留一份可回滚的副本，再整份替换。
        _ = try? await ufi.rootShell("cp \(configPath) \(configPath).crbak", timeoutMS: 15_000)
        try await ufi.writeFile(configPath, contents: manifest)
        // 必须 stop → start（不能传 restart，clashctl 不认）。
        // 这一步会重新下载所有订阅 + 规则集，慢是正常的。
        try await restart()

        // 等 clashctl 把清单展开成完整配置。
        // ⚠️ 它会**写两遍**（生成 → 校验/规范化），所以必须等文件稳定下来再往下走，
        // 否则后面的「收敛策略组」会读到中间态，甚至撞上文件被短暂移走的窗口。
        var previousDigest = ""
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(3))
            let probe = (try? await ufi.rootShell(
                "if [ -f \(configPath) ]; then "
                    + "printf '%s %s %s' \"$(wc -c < \(configPath))\" "
                    + "\"$(grep -c '^proxy-groups:' \(configPath))\" "
                    + "\"$(printf '%s' \"$(cat \(configPath))\" | md5sum | cut -d' ' -f1)\"; "
                    + "else echo MISSING; fi",
                timeoutMS: 20_000
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard probe != "MISSING", !probe.isEmpty else { previousDigest = ""; continue }
            let parts = probe.split(separator: " ").map(String.init)
            guard parts.count >= 3,
                  let size = Int(parts[0]), size > 500,
                  parts[1] != "0" else {
                previousDigest = ""
                continue
            }
            if parts[2] == previousDigest { return }
            previousDigest = parts[2]
        }
        throw HTTPError.message("订阅清单已写入，但路由器还没稳定生成出完整配置，请点刷新确认。")
    }

    /// 猫猫的「过滤规则同步」：把按用途分的策略组收成一个「节点选择」，并把规则目标、
    /// 以及保留下来的组里的引用一起重映射；再用 exclude-filter 剔除要排除的节点。
    func flattenPolicyGroups(configPath: String, nodeFilter: String?) async throws {
        let yaml = try await ufi.readFile(configPath)
        let next = try MaoMaoPolicyYAML.rewrite(yaml, excludeRegex: nodeFilter ?? "")
        guard next != yaml else { return }
        try validate(next, against: yaml)
        try await ufi.writeFile(configPath, contents: next)
        try await restart()
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws {
        let name = sanitizeProviderName(sub.name)
        let url = sub.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError.message("订阅名称不能为空") }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw HTTPError.message("订阅链接需要 http/https")
        }
        var yaml = try await ufi.readFile(configPath)
        let original = yaml
        if isNew {
            yaml = try insertProvider(named: name, url: url, into: yaml)
        } else {
            let oldName = sanitizeProviderName(sub.section.isEmpty ? sub.name : sub.section)
            yaml = try updateProvider(named: oldName, newName: name, url: url, in: yaml)
        }
        try await commitConfig(yaml, original: original)
    }

    func deleteSubscription(_ sub: Subscription) async throws {
        let name = sanitizeProviderName(sub.section.isEmpty ? sub.name : sub.section)
        guard !name.isEmpty else { throw HTTPError.message("订阅名称无效") }
        let yaml = try await ufi.readFile(configPath)
        let next = try removeProvider(named: name, from: yaml)
        try await commitConfig(next, original: yaml)
    }

    func selectProxy(group: String, name: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        _ = try await clashRequest("/proxies/\(encoded)", method: "PUT", json: ["name": name])
    }

    func testDelay(name: String, timeoutMs: Int) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let bounded = min(max(timeoutMs, 500), 15_000)
        let dict = try await clashJSON(
            "/proxies/\(encoded)/delay",
            query: ["timeout": "\(bounded)", "url": "http://www.gstatic.com/generate_204"],
            timeout: Double(bounded) / 1000 + 3
        )
        return JSONValue.int(dict["delay"])
    }

    func testGroupDelay(group: String, timeoutMs: Int) async throws -> [String: Int] {
        try await ClashDelayProbe.groupDelay(group: group, timeoutMs: timeoutMs) { path, query, timeout in
            try await clashRequest(path, query: query, timeout: timeout)
        }
    }

    func addDirectRule(domain: String, proxy: String, configPath: String) async throws {
        let host = DomainRulePolicy.host(from: domain)
        guard !host.isEmpty else { throw HTTPError.message("域名无效") }
        let type = host.contains("*") || host.contains("/") ? "DOMAIN-KEYWORD" : "DOMAIN-SUFFIX"
        let payload = host.replacingOccurrences(of: "*.", with: "")
        let line = "- \(type),\(payload),\(proxy)"
        try await mutateConfig { raw in
            if raw.contains("\(type),\(payload),") {
                throw HTTPError.message("规则已存在")
            }
            return try DomainRulePolicy.insertRuleLine(raw, line: line)
        }
    }

    func upsertProfileRule(_ rule: LocalDomainRule, configPath: String) async throws {
        try await mutateConfig { try DomainRulePolicy.upsertRuleLine($0, rule: rule) }
    }

    private func mutateConfig(_ mutate: (String) throws -> String) async throws {
        let yaml = try await ufi.readFile(self.configPath)
        let next = try mutate(yaml)
        if next == yaml { return }
        try await commitConfig(next, original: yaml)
    }

    /// 写回配置前的一致性校验。读取被截断/失败时如果照写，会把路由器上的完整配置
    /// 覆盖成残片，猫猫核心随后会因为配置不完整起不来 —— 表现就是 Clash API 端口不通、
    /// App「连不上路由器」。所以这里宁可中止，也不能写坏。
    private func validate(_ next: String, against original: String) throws {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPError.message("准备写入的配置是空的，已中止，未改动 \(configPath)。")
        }
        let markers = ["proxies:", "proxy-providers:", "proxy-groups:", "rules:"]
        guard markers.contains(where: { trimmed.contains($0) }) else {
            throw HTTPError.message("写入内容缺少 proxies / proxy-groups / rules 段落，已中止，未改动 \(configPath)。")
        }
        if original.count > 4096, next.count < original.count / 2 {
            throw HTTPError.message("配置从 \(original.count) 字节骤减到 \(next.count) 字节，像是读取失败，已中止写入。")
        }
    }

    private func commitConfig(_ next: String, original: String) async throws {
        try validate(next, against: original)
        try await ufi.writeFile(configPath, contents: next)
        try await restart()
    }

    func closeConnections() async throws {
        _ = try await clashRequest("/connections", method: "DELETE")
    }

    func installDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        try await ufi.writeFile(NodeFailoverScript.path, contents: NodeFailoverScript.source)
        try await ufi.writeFile(
            NodeFailoverScript.confPath,
            contents: NodeFailoverScript.conf(secret: clashSecret, interval: interval, enabled: enabled, profile: profile)
        )
        _ = try await ufi.rootShell(
            "mkdir -p /data/clash/Scripts; chmod 755 \(NodeFailoverScript.path)"
        )

        let current = try await ufi.readFile(NodeFailoverScript.servicePath)
        if !current.contains(NodeFailoverScript.markerBegin) {
            _ = try await ufi.rootShell(
                "cp \(NodeFailoverScript.servicePath) \(NodeFailoverScript.bakPath)"
            )
        }
        try await ufi.writeFile(NodeFailoverScript.servicePath, contents: NodeFailoverScript.wrapperService())
        _ = try await ufi.rootShell("chmod 755 \(NodeFailoverScript.servicePath) \(NodeFailoverScript.bakPath)")
        let started = try await ufi.rootShell(NodeFailoverScript.startCommand)
        if !started.lowercased().contains("started") {
            throw HTTPError.message(started.isEmpty ? "守护没有启动起来" : started)
        }
    }

    func uninstallDeviceFailover() async throws {
        _ = try await ufi.rootShell("\(NodeFailoverScript.path) stop >/dev/null 2>&1")
        _ = try await ufi.rootShell(
            "if [ -f \(NodeFailoverScript.bakPath) ]; then cp \(NodeFailoverScript.bakPath) \(NodeFailoverScript.servicePath); chmod 755 \(NodeFailoverScript.servicePath); fi"
        )
        _ = try await ufi.rootShell(
            "rm -f \(NodeFailoverScript.path) \(NodeFailoverScript.confPath) \(NodeFailoverScript.pidPath) \(NodeFailoverScript.statusPath) \(NodeFailoverScript.pinPath)"
        )
    }

    func updateDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        let exists = try await ufi.rootShell("test -f \(NodeFailoverScript.path) && echo yes")
        guard exists.contains("yes") else {
            try await installDeviceFailover(interval: interval, enabled: enabled, profile: profile)
            return
        }
        try await ufi.writeFile(
            NodeFailoverScript.confPath,
            contents: NodeFailoverScript.conf(secret: clashSecret, interval: interval, enabled: enabled, profile: profile)
        )
        let running = try await ufi.rootShell(
            "if [ -f \(NodeFailoverScript.pidPath) ]; then pid=$(cat \(NodeFailoverScript.pidPath)); [ -d /proc/$pid ] && echo yes; fi"
        )
        if !running.contains("yes") {
            _ = try await ufi.rootShell(NodeFailoverScript.startCommand)
        }
    }

    func deviceFailoverStatus() async throws -> DeviceFailoverStatus {
        let dump = try await ufi.rootShell(
            """
            echo INSTALLED=$(test -f \(NodeFailoverScript.path) && echo yes || echo no)
            echo HOOKED=$(grep -q clashremote-node-failover \(NodeFailoverScript.servicePath) 2>/dev/null && echo yes || echo no)
            if [ -f \(NodeFailoverScript.pidPath) ]; then pid=$(cat \(NodeFailoverScript.pidPath)); [ -d /proc/$pid ] && echo RUNNING=yes || echo RUNNING=no; else echo RUNNING=no; fi
            echo '---CONF---'
            cat \(NodeFailoverScript.confPath) 2>/dev/null
            echo '---STATUS---'
            cat \(NodeFailoverScript.statusPath) 2>/dev/null
            echo '---LOG---'
            tail -n 12 \(NodeFailoverScript.logPath) 2>/dev/null
            """,
            timeoutMS: 8_000
        )
        return NodeFailoverScript.parseStatusDump(dump)
    }

    func runDeviceFailoverOnce() async throws {
        _ = try await ufi.rootShell(
            "\(NodeFailoverScript.path) once",
            timeoutMS: 40_000
        )
    }

    func deviceFailoverHistory() async throws -> [FailoverEvent] {
        let raw = (try? await ufi.rootShell(
            "tail -n 80 \(NodeFailoverScript.historyPath) 2>/dev/null",
            timeoutMS: 8_000
        )) ?? ""
        return NodeFailoverScript.parseHistory(raw)
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

    private func parseProviders(_ yaml: String) -> [(name: String, url: String)] {
        guard let section = providerSection(yaml) else { return [] }
        let lines = section.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var providerIndent: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            providerIndent = line.prefix { $0 == " " }.count
            break
        }
        guard let providerIndent else { return [] }

        var result: [(String, String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == providerIndent, trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
                let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                var block = line + "\n"
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty {
                        block += next + "\n"
                        i += 1
                        continue
                    }
                    let nextIndent = next.prefix { $0 == " " }.count
                    if nextIndent <= providerIndent { break }
                    block += next + "\n"
                    i += 1
                }
                if let url = urlLine(in: block) {
                    result.append((name, url))
                }
                continue
            }
            i += 1
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

    /// 取 provider **自己那层**的 `url:`，绝不能用 health-check 里的那个。
    ///
    /// clashctl 生成的配置里键是**按字母序**排的（`health-check` 排在 `url` 前面），
    /// 而 `health-check.url` 也是 https 开头 —— 按"第一个 http 开头的 url"取会拿到
    /// `https://www.gstatic.com/generate_204`，界面上看起来像是三个相同的订阅，
    /// 点「更新」还会真去下载那个 204 页面。所以这里按缩进只认 provider 自己那层的 key。
    private func urlLine(in body: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        // 第一行是 provider 名字，跳过；剩下最浅的一层才是 provider 自己的 key
        let rest = lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.dropFirst()
        guard let base = rest.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(indent).min()
        else { return nil }
        for line in rest where indent(line) == base {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url:") else { continue }
            let value = trimmed.dropFirst(4)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // 插件的空占位槽 url 是「你的订阅链接3」这种非 http 值，会被这里过滤掉，
            // 正好不会在订阅列表里冒出第三个不存在的订阅。
            if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        }
        return nil
    }

    private func downloadSubscription(url: String, into path: String) async throws {
        let escapedURL = url.replacingOccurrences(of: "'", with: "'\\''")
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        curl -fsSL --max-time 90 -A 'clash.meta' -o '\(escapedPath).tmp' '\(escapedURL)' && test -s '\(escapedPath).tmp' && mv '\(escapedPath).tmp' '\(escapedPath)'
        """
        _ = try await ufi.rootShell(cmd, timeoutMS: 120_000)
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
        if let urlRange = updated.range(of: #"(?m)^[ \t]*url: .+$"#, options: .regularExpression) {
            let indent = updated[urlRange].prefix { $0 == " " || $0 == "\t" }
            updated.replaceSubrange(urlRange, with: "\(indent)url: \"\(url)\"")
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
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^([ \t]+)"# + NSRegularExpression.escapedPattern(for: name) + #":\s*$"#) else {
            return nil
        }
        let ns = NSRange(yaml.startIndex..<yaml.endIndex, in: yaml)
        guard let match = regex.firstMatch(in: yaml, range: ns),
              let start = Range(match.range, in: yaml),
              let indentRange = Range(match.range(at: 1), in: yaml) else {
            return nil
        }
        let indentCount = yaml[indentRange].count
        var idx = start.upperBound
        if idx < yaml.endIndex, yaml[idx] == "\n" {
            idx = yaml.index(after: idx)
        }
        while idx < yaml.endIndex {
            let rest = yaml[idx...]
            guard let lineEnd = rest.firstIndex(of: "\n") else {
                return start.lowerBound..<yaml.endIndex
            }
            let line = yaml[idx..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                idx = yaml.index(after: lineEnd)
                continue
            }
            let lineIndent = line.prefix { $0 == " " || $0 == "\t" }.count
            if lineIndent <= indentCount {
                return start.lowerBound..<idx
            }
            idx = yaml.index(after: lineEnd)
        }
        return start.lowerBound..<yaml.endIndex
    }

    private func addProviderToUseLists(_ name: String, in yaml: String) -> String {
        if yaml.contains("- \(name)\n") { return yaml }
        var next = yaml
        let pattern = #"(?m)^([ \t]+use:\s*\n(?:[ \t]+- .+\n)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        let ns = NSRange(next.startIndex..<next.endIndex, in: next)
        let matches = regex.matches(in: next, range: ns).reversed()
        for match in matches {
            guard let range = Range(match.range, in: next) else { continue }
            var block = String(next[range])
            if block.contains("- \(name)\n") { continue }
            let indent: String = {
                for line in block.split(separator: "\n").dropFirst() {
                    let s = String(line)
                    if s.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        return String(s.prefix { $0 == " " || $0 == "\t" })
                    }
                }
                return "    "
            }()
            if !block.hasSuffix("\n") { block += "\n" }
            block += "\(indent)- \(name)\n"
            next.replaceSubrange(range, with: block)
        }
        return next
    }

    private func providerBlock(name: String, url: String, index: String) -> String {
        """
          \(name):
            type: http
            url: "\(url)"
            path: ./proxies/\(name).yaml
            interval: 86400
            override:
              additional-prefix: '[\(index)]'
            health-check:
              enable: true
              interval: 600
              lazy: false
              timeout: 3000
              url: https://www.gstatic.com/generate_204

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
                    selectable: ProxyGroup.allowsManualSelect(type: type, name: name)
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
        json: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let response = try await clashRequest(path, method: method, query: query, json: json, timeout: timeout)
        if response.data.isEmpty { return [:] }
        return try response.jsonDict()
    }

    private func clashRequest(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        json: [String: Any]? = nil,
        timeout: TimeInterval? = nil
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
        let response = try await http.request(url: url, method: method, headers: headers, body: body, timeout: timeout)
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
