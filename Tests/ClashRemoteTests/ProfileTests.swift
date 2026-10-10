import XCTest
@testable import ClashRemote

final class ProfileTests: XCTestCase {
    func testDefaultExclusionsAndTaiwan() {
        var profile = LocalProfile.default
        XCTAssertTrue(profile.shouldExcludeNode("乌拉VPN 香港 01"))
        XCTAssertTrue(profile.shouldExcludeNode("渔云 中国上海 01"))
        XCTAssertFalse(profile.shouldExcludeNode("乌拉VPN 台湾台北 01"))
        XCTAssertFalse(profile.shouldExcludeNode("渔云 日本 01"))
        XCTAssertFalse(profile.shouldExcludeNode("其他机场 日本 01"))
        profile.providerWhitelistEnabled = true
        XCTAssertTrue(profile.shouldExcludeNode("其他机场 日本 01"))
    }

    func testNestedGroupsAreTraversedBeforeFilteringLeaves() {
        let root = ProxyGroup(
            name: "漏网之鱼", type: "Selector", now: "日本节点", nodes: [
                ProxyItem(name: "日本节点", type: "Selector", lastDelay: nil)
            ], selectable: true
        )
        let child = ProxyGroup(
            name: "日本节点", type: "Selector", now: "乌拉VPN 日本 01", nodes: [
                ProxyItem(name: "乌拉VPN 日本 01", type: "Shadowsocks", lastDelay: 80),
                ProxyItem(name: "其它机场 日本 02", type: "Shadowsocks", lastDelay: 70)
            ], selectable: true
        )
        let nodes = NodeBoardLayout.flattenLeaves(
            from: root, groups: [root, child], putGroup: root.name, profile: .default
        )
        XCTAssertEqual(Set(nodes.map(\.name)), Set(["其它机场 日本 02", "乌拉VPN 日本 01"]))
        XCTAssertTrue(nodes.allSatisfy { $0.ownerGroup == "日本节点" })
        var filtered = LocalProfile.default
        filtered.providerWhitelistEnabled = true
        XCTAssertEqual(NodeBoardLayout.flattenLeaves(
            from: root, groups: [root, child], putGroup: root.name, profile: filtered
        ).map(\.name), ["乌拉VPN 日本 01"])
    }

    func testConfigurableFiltersAndRegex() throws {
        var profile = LocalProfile.default
        profile.filterKeywords = ["官网", "到期"]
        profile.regionExclusions = []
        profile.providerWhitelistEnabled = false
        XCTAssertFalse(profile.shouldExcludeNode("任意机场 香港"))
        XCTAssertTrue(profile.shouldExcludeNode("任意机场 官网"))
        let regex = try NSRegularExpression(pattern: profile.nodeExcludeRegex())
        XCTAssertNil(regex.firstMatch(in: "正常节点", range: NSRange("正常节点".startIndex..., in: "正常节点")))
        XCTAssertNotNil(regex.firstMatch(in: "官网提示", range: NSRange("官网提示".startIndex..., in: "官网提示")))
        profile.filterKeywords = []
        XCTAssertEqual(profile.nodeExcludeRegex(), "")
    }

    func testRouterFilterUsesSupportedExcludeField() {
        let yaml = """
        proxy-providers:
          sample:
            type: http
            url: https://example.com/sub
        proxy-groups:
          - name: old
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,old
        """
        let rewritten = SimplePolicyYAML.rewrite(yaml, nodeFilter: LocalProfile.default.nodeExcludeRegex())
        XCTAssertTrue(rewritten.contains("exclude-filter:"))
        XCTAssertFalse(rewritten.contains("(?!"))
        let unfiltered = SimplePolicyYAML.rewrite(yaml, nodeFilter: "")
        XCTAssertFalse(unfiltered.contains("exclude-filter:"))
    }

    func testDomainRuleUpsertIsIdempotentAndKeepsType() throws {
        let rule = LocalDomainRule(domain: "example.com", ruleType: "DOMAIN-KEYWORD", proxy: "REJECT")
        let first = try DomainRulePolicy.upsertRuleLine("rules:\n  - MATCH,GLOBAL\n", rule: rule)
        XCTAssertTrue(first.contains("- DOMAIN-KEYWORD,example.com,REJECT"))
        XCTAssertEqual(try DomainRulePolicy.upsertRuleLine(first, rule: rule), first)
        let changed = try DomainRulePolicy.upsertRuleLine(
            first, rule: LocalDomainRule(domain: "example.com", ruleType: "DOMAIN-KEYWORD", proxy: "DIRECT")
        )
        XCTAssertFalse(changed.contains("DOMAIN-KEYWORD,example.com,REJECT"))
        XCTAssertTrue(changed.contains("DOMAIN-KEYWORD,example.com,DIRECT"))
    }

    func testBlocklistStopsFailoverButKeepsNodeVisible() throws {
        var profile = LocalProfile.default
        profile.regionExclusions = []
        profile.blockedNodes = ["乌拉VPN 日本 01"]
        // 拉黑 = 自动换节点跳过，但列表里还要留着（灰掉、可一键解除）
        XCTAssertTrue(profile.isBlocked("乌拉VPN 日本 01"))
        XCTAssertTrue(profile.shouldExcludeNode("乌拉VPN 日本 01"))
        XCTAssertFalse(profile.isFilteredOut("乌拉VPN 日本 01"))
        XCTAssertFalse(profile.isBlocked("乌拉VPN 日本 02"))
        XCTAssertFalse(profile.shouldExcludeNode("乌拉VPN 日本 02"))

        // 关键词拉黑 = 整个订阅 / 机场一起挡掉
        profile.blockedKeywords = ["渔云"]
        XCTAssertTrue(profile.isBlocked("渔云 新加坡 03"))
        XCTAssertTrue(profile.shouldExcludeNode("渔云 新加坡 03"))
        XCTAssertFalse(profile.isFilteredOut("渔云 新加坡 03"))
        XCTAssertFalse(profile.isBlocked("鱼云 新加坡 03"))
        XCTAssertEqual(profile.blockedCount, 2)

        // 拉黑项也要进路由器 filter 正则，否则路由器上的「节点选择」组还会留着它们
        let pattern = try XCTUnwrap(NSRegularExpression(pattern: profile.nodeExcludeRegex()))
        for name in ["乌拉VPN 日本 01", "渔云 新加坡 03"] {
            XCTAssertNotNil(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)))
        }
    }

    func testLegacyProfileJSONSurvivesUpgrade() throws {
        // 老版本写下的 profile.json 没有黑名单字段，升级后不能把用户配置整个丢掉。
        let legacy = """
        {"failoverThreshold":150,"filterKeywords":["官网"],"providerWhitelist":[],
         "providerWhitelistEnabled":false,"regionExclusions":["hongkong"],
         "subscriptions":[],"domainRules":[]}
        """
        let profile = try JSONDecoder().decode(LocalProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(profile.failoverThreshold, 150)
        XCTAssertEqual(profile.filterKeywords, ["官网"])
        XCTAssertTrue(profile.blockedNodes.isEmpty)
        XCTAssertTrue(profile.blockedKeywords.isEmpty)
    }

    func testBlocklistSurvivesRoundTrip() throws {
        var profile = LocalProfile.default
        profile.blockedNodes = ["A 01"]
        profile.blockedKeywords = ["渔云"]
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(LocalProfile.self, from: data), profile)
    }

    func testDeviceConfCarriesBlocklist() {
        var profile = LocalProfile.default
        profile.blockedNodes = ["A 01"]
        profile.blockedKeywords = ["渔云"]
        let conf = NodeFailoverScript.profileConf(profile)
        XCTAssertTrue(conf.contains("BLOCKED_NODES='A 01'"))
        XCTAssertTrue(conf.contains("BLOCKED_KEYWORDS='渔云'"))
        // 脚本本体要自带空默认值，旧 conf 缺字段时不会因为未定义变量报错
        XCTAssertTrue(NodeFailoverScript.source.contains("BLOCKED_NODES=''"))
        XCTAssertTrue(NodeFailoverScript.source.contains("BLOCKED_KEYWORDS=''"))
        XCTAssertTrue(NodeFailoverScript.source.contains("is_blocked() {"))
        XCTAssertTrue(OpenClashFailover.source.contains("is_blocked() {"))
    }

    func testDeviceProfileConfig() {
        let profile = LocalProfile.default
        let conf = NodeFailoverScript.profileConf(profile)
        XCTAssertTrue(conf.contains("FAILOVER_THRESHOLD=180"))
        XCTAssertTrue(conf.contains("EXCLUDE_REGIONS='hongkong,china'"))
        XCTAssertTrue(conf.contains("PROVIDER_WHITELIST='乌拉\n渔云'"))
        XCTAssertTrue(conf.contains("WHITELIST_ENABLED=0"))
        XCTAssertTrue(OpenClashFailover.hookBlock(interval: 5, enabled: true, profile: profile)
            .contains("<< 'CR_FAILOVER_PROFILE_EOF'"))
        var custom = profile
        custom.filterKeywords = ["safe", "can't", "CR_FAILOVER_PROFILE_EOF"]
        let safeConf = NodeFailoverScript.profileConf(custom)
        XCTAssertTrue(safeConf.contains("can'\\''t"))
        XCTAssertFalse(safeConf.split(separator: "\n").contains("CR_FAILOVER_PROFILE_EOF"))
        XCTAssertTrue(NodeFailoverScript.conf(secret: "a'$(touch /tmp/unsafe)", interval: 5, enabled: true, profile: custom)
            .contains("SECRET='a'\\''$(touch /tmp/unsafe)'"))
    }

    func testPinnedNodeOnlySwitchesOnTimeout() {
        var profile = LocalProfile.default
        XCTAssertFalse(profile.pinnedNode, "默认不固定")
        XCTAssertEqual(profile.effectiveFailoverThreshold, 180)
        profile.pinnedNode = true
        XCTAssertEqual(profile.effectiveFailoverThreshold, 0, "固定时有效阈值应归零")
        profile.failoverThreshold = 260
        XCTAssertEqual(profile.effectiveFailoverThreshold, 0, "固定时应忽略配置里的阈值")
        profile.pinnedNode = false
        XCTAssertEqual(profile.effectiveFailoverThreshold, 260, "取消固定后应恢复原阈值")
    }

    func testPinnedNodeReachesDeviceAndPanel() {
        var profile = LocalProfile.default
        profile.pinnedNode = true
        let conf = NodeFailoverScript.profileConf(profile)
        XCTAssertTrue(conf.contains("PIN_MODE=1"))
        XCTAssertTrue(conf.contains("FAILOVER_THRESHOLD=180"), "阈值本身仍要留在 conf 里，关掉固定后才能恢复")
        XCTAssertTrue(NodeFailoverScript.profileConf(.default).contains("PIN_MODE=0"))
        // 脚本要自带默认值 + 固定状态输出，旧 conf 缺字段也不能出错
        XCTAssertTrue(NodeFailoverScript.source.contains("PIN_MODE=0"))
        XCTAssertTrue(NodeFailoverScript.source.contains("PINFILE="))
        XCTAssertTrue(NodeFailoverScript.source.contains("pinned ${leaf}"))
        XCTAssertTrue(NodeFailoverScript.source.contains("rm -f \"$PINFILE\""))
        // OpenClash 那份是字符串替换派生的，pin 路径必须换掉，不能留着猫猫的路径
        XCTAssertTrue(OpenClashFailover.source.contains("/etc/openclash/clashremote-failover.pin"))
        XCTAssertFalse(OpenClashFailover.source.contains("/data/clash/Scripts/node-failover.pin"))
    }
}
