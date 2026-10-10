import Foundation

@MainActor
protocol ClashBackend: AnyObject {
    func connect() async throws -> DashboardSnapshot
    func refresh(full: Bool) async throws -> DashboardSnapshot
    func setRunning(_ running: Bool) async throws
    func restart() async throws
    func setRuleMode(_ mode: RuleMode) async throws
    func setCapture(_ capture: RunCapture) async throws
    func setOCSetting(_ name: String, value: Bool) async throws
    func setChinaIPRoute(_ enabled: Bool) async throws
    func switchConfig(_ file: ConfigFile) async throws
    func updateConfig(filename: String) async throws
    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws
    func deleteSubscription(_ sub: Subscription) async throws
    /// 把本地配置里的订阅列表整体推到路由器。
    /// OpenClash：逐个新增/更新 proxy-providers（默认实现）；猫猫：整份替换成插件自己的「订阅清单」。
    func applySubscriptions(_ subs: [LocalSubscription], existing: [Subscription]) async throws
    /// 这台设备是否需要 App 去折叠策略组。
    /// OpenClash 的配置容易堆出一堆重复组，需要收成一个「节点选择」；
    /// 猫猫生成的策略组自带 `filter:` 正则（AIGPT / Netflix / Steam 等按用途分组），折叠会把这些功能毁掉。
    var needsGroupFlattening: Bool { get }
    func selectProxy(group: String, name: String) async throws
    /// 单个节点测延迟。`timeoutMs` 是内核侧的等待上限：卡住的节点会一直等到这个值才返回。
    func testDelay(name: String, timeoutMs: Int) async throws -> Int
    /// 让内核自己把整个策略组测一遍（`GET /group/{name}/delay`）。
    ///
    /// 一个请求测完整组，内核内部并发，耗时只取决于 `timeoutMs`——
    /// 而逐个 `/proxies/{name}/delay` 是 N 个请求、本机侧还得自己分批，
    /// 只要有一批里撞上超时节点，整批都要等满超时，几十个节点就要等几十秒。
    ///
    /// ⚠️ 返回值**只包含测通的节点**：组里没测通的节点（超时/失败）不会出现在字典里。
    func testGroupDelay(group: String, timeoutMs: Int) async throws -> [String: Int]
    func addDirectRule(domain: String, proxy: String, configPath: String) async throws
    func upsertProfileRule(_ rule: LocalDomainRule, configPath: String) async throws
    func flattenPolicyGroups(configPath: String, nodeFilter: String?) async throws
    func closeConnections() async throws
    func installDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws
    func uninstallDeviceFailover() async throws
    func updateDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws
    func deviceFailoverStatus() async throws -> DeviceFailoverStatus
    func runDeviceFailoverOnce() async throws
    func deviceFailoverHistory() async throws -> [FailoverEvent]
}

extension ClashBackend {
    /// 默认实现（OpenClash）：逐个新增/更新 proxy-providers。
    func applySubscriptions(_ subs: [LocalSubscription], existing: [Subscription]) async throws {
        for sub in subs {
            let installed = existing.first { $0.name == sub.name }
            let routerSub = Subscription(
                section: installed?.section ?? "",
                name: sub.name,
                address: sub.url,
                enabled: true,
                userAgent: sub.userAgent
            )
            let unchanged = installed?.address == routerSub.address
                && installed?.userAgent == routerSub.userAgent
                && installed?.enabled == true
            if !unchanged {
                try await saveSubscription(routerSub, isNew: installed == nil)
            }
        }
    }

    var needsGroupFlattening: Bool { true }

    func installDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        throw HTTPError.message("这台设备还不支持机内守护")
    }

    func uninstallDeviceFailover() async throws {
        throw HTTPError.message("这台设备还不支持机内守护")
    }

    func updateDeviceFailover(interval: Int, enabled: Bool, profile: LocalProfile) async throws {
        throw HTTPError.message("这台设备还不支持机内守护")
    }

    func deviceFailoverStatus() async throws -> DeviceFailoverStatus {
        DeviceFailoverStatus()
    }

    func runDeviceFailoverOnce() async throws {
        throw HTTPError.message("这台设备还不支持机内守护")
    }

    func deviceFailoverHistory() async throws -> [FailoverEvent] {
        []
    }
}

extension OpenClashService: ClashBackend {}

extension ClashBackend {
    func testDelay(name: String) async throws -> Int {
        try await testDelay(name: name, timeoutMs: 5_000)
    }
}

/// 整组测速的公共实现：路径与返回值解析两端一致，只有「怎么发请求」不同。
@MainActor
enum ClashDelayProbe {
    static let probeURL = "http://www.gstatic.com/generate_204"

    static func groupDelay(
        group: String,
        timeoutMs: Int,
        _ send: (String, [String: String], TimeInterval) async throws -> HTTPResponse
    ) async throws -> [String: Int] {
        let bounded = min(max(timeoutMs, 500), 15_000)
        // 不要自己先 percent-encode：URLComponents 会对 `%` 再转义一次，
        // 拼出来就变成 %25E9…（内核对这种双重编码是宽容的，但没必要依赖它）。
        let response = try await send(
            "/group/\(group)/delay",
            ["timeout": "\(bounded)", "url": probeURL],
            Double(bounded) / 1000 + 6
        )
        return decodeMap(response)
    }

    /// 只保留测通的节点；没测通的节点内核不会返回，缺失即视为超时。
    static func decodeMap(_ response: HTTPResponse) -> [String: Int] {
        guard let object = (try? response.jsonObject()) as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (name, value) in object {
            let delay = JSONValue.int(value)
            if delay > 0 { out[name] = delay }
        }
        return out
    }
}
