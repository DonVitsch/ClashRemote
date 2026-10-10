import Foundation

struct LocalProfile: Codable, Equatable {
    var subscriptions: [LocalSubscription]
    var filterKeywords: [String]
    var regionExclusions: Set<RegionExclusion>
    var providerWhitelist: [String]
    var providerWhitelistEnabled: Bool
    var domainRules: [LocalDomainRule]
    var failoverThreshold: Int
    /// 「固定当前节点」：不再因为「慢」而换节点，只有当前节点真的超时才自动换（阈值等价于 0）。
    var pinnedNode: Bool
    /// 用户主动拉黑的节点（完整名称精确匹配）。
    var blockedNodes: [String]
    /// 用户主动拉黑的关键词：节点名命中就整批拉黑，用来拉黑「整个订阅 / 机场的节点」。
    var blockedKeywords: [String]

    static let `default` = LocalProfile(
        subscriptions: [],
        filterKeywords: defaultFilterKeywords,
        regionExclusions: [.hongkong, .china],
        providerWhitelist: ["乌拉", "渔云"],
        providerWhitelistEnabled: false,
        domainRules: [],
        failoverThreshold: 180,
        pinnedNode: false,
        blockedNodes: [],
        blockedKeywords: []
    )

    static let defaultFilterKeywords = [
        "剩余", "到期", "流量", "过期", "官网", "套餐", "重置", "故障转移",
        "距离下次"
    ]

    init(
        subscriptions: [LocalSubscription],
        filterKeywords: [String],
        regionExclusions: Set<RegionExclusion>,
        providerWhitelist: [String],
        providerWhitelistEnabled: Bool,
        domainRules: [LocalDomainRule],
        failoverThreshold: Int,
        pinnedNode: Bool = false,
        blockedNodes: [String] = [],
        blockedKeywords: [String] = []
    ) {
        self.subscriptions = subscriptions
        self.filterKeywords = filterKeywords
        self.regionExclusions = regionExclusions
        self.providerWhitelist = providerWhitelist
        self.providerWhitelistEnabled = providerWhitelistEnabled
        self.domainRules = domainRules
        self.failoverThreshold = failoverThreshold
        self.pinnedNode = pinnedNode
        self.blockedNodes = blockedNodes
        self.blockedKeywords = blockedKeywords
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptions, filterKeywords, regionExclusions, providerWhitelist
        case providerWhitelistEnabled, domainRules, failoverThreshold, pinnedNode
        case blockedNodes, blockedKeywords
    }

    /// 手写解码：老版本写下的 profile.json 里没有黑名单 / 固定节点字段，
    /// 用 decodeIfPresent 兜底，免得升级后把用户已有的配置整个丢掉。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([LocalSubscription].self, forKey: .subscriptions) ?? []
        filterKeywords = try container.decodeIfPresent([String].self, forKey: .filterKeywords)
            ?? Self.defaultFilterKeywords
        regionExclusions = try container.decodeIfPresent(Set<RegionExclusion>.self, forKey: .regionExclusions)
            ?? [.hongkong, .china]
        providerWhitelist = try container.decodeIfPresent([String].self, forKey: .providerWhitelist)
            ?? ["乌拉", "渔云"]
        providerWhitelistEnabled = try container.decodeIfPresent(Bool.self, forKey: .providerWhitelistEnabled)
            ?? false
        domainRules = try container.decodeIfPresent([LocalDomainRule].self, forKey: .domainRules) ?? []
        failoverThreshold = try container.decodeIfPresent(Int.self, forKey: .failoverThreshold) ?? 180
        pinnedNode = try container.decodeIfPresent(Bool.self, forKey: .pinnedNode) ?? false
        blockedNodes = try container.decodeIfPresent([String].self, forKey: .blockedNodes) ?? []
        blockedKeywords = try container.decodeIfPresent([String].self, forKey: .blockedKeywords) ?? []
    }

    /// 自动换节点真正使用的阈值：固定当前节点时归零 —— 只要还通就不换。
    var effectiveFailoverThreshold: Int {
        pinnedNode ? 0 : failoverThreshold
    }

    /// 用户主动拉黑的判定：精确名字或关键词命中。拉黑优先级高于一切筛选设置。
    func isBlocked(_ name: String) -> Bool {
        if blockedNodes.contains(name) { return true }
        for keyword in blockedKeywords where !keyword.isEmpty {
            if name.localizedCaseInsensitiveContains(keyword) { return true }
        }
        return false
    }

    var blockedCount: Int {
        blockedNodes.filter { !$0.isEmpty }.count + blockedKeywords.filter { !$0.isEmpty }.count
    }

    /// 展示层面的筛选：关键词 / 地区 / 机场白名单 —— 命中就从节点列表里拿掉。
    func isFilteredOut(_ name: String) -> Bool {
        let folded = name.lowercased()
        for keyword in filterKeywords {
            if !keyword.isEmpty && name.localizedCaseInsensitiveContains(keyword) { return true }
        }
        for region in regionExclusions {
            if region.matches(name, folded: folded) { return true }
        }
        if providerWhitelistEnabled, !providerWhitelist.isEmpty {
            let hits = providerWhitelist.contains { provider in
                !provider.isEmpty && name.localizedCaseInsensitiveContains(provider)
            }
            if !hits { return true }
        }
        return false
    }

    /// 自动换节点的候选判定 = 用户拉黑 ∪ 筛选。
    /// 注意：拉黑的节点**仍然显示**在节点列表里（灰掉、可一键解除），只是不会被自动选中 ——
    /// 这样用户点错了能马上看见、马上撤销，而不是去别处找一个看不见的黑名单。
    func shouldExcludeNode(_ name: String) -> Bool {
        isBlocked(name) || isFilteredOut(name)
    }

    /// 写进路由器配置 filter 的正则：关键词 + 拉黑项，让路由器上的「节点选择」组也不含它们。
    func nodeExcludeRegex() -> String {
        let terms = filterKeywords + blockedKeywords + blockedNodes
        let escaped = terms.filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        if escaped.isEmpty { return "" }
        return "(?i)(\(escaped.joined(separator: "|")))"
    }
}

struct LocalSubscription: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var userAgent: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, url: String,
         userAgent: String = "clash.meta", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.userAgent = userAgent
        self.enabled = enabled
    }
}

enum RegionExclusion: String, Codable, CaseIterable, Identifiable, Hashable {
    case hongkong = "香港"
    case china = "中国大陆"
    case japan = "日本"
    case usa = "美国"
    case singapore = "新加坡"

    var id: String { rawValue }

    var label: String { rawValue }

    var note: String {
        switch self {
        case .china: "不含台湾"
        default: ""
        }
    }

    func matches(_ name: String, folded: String? = nil) -> Bool {
        let f = folded ?? name.lowercased()
        switch self {
        case .hongkong:
            return name.contains("香港") || name.contains("🇭🇰")
                || f.contains("hong kong") || f.contains("hongkong") || f.contains("hong-kong")
        case .china:
            let isCN = name.contains("中国") || name.contains("大陆") || name.contains("🇨🇳")
                || f.contains("china") || f.contains("shanghai") || f.contains("beijing")
                || f.contains("shenzhen") || f.contains("guangzhou") || f.contains("chengdu")
            let isTW = name.contains("台湾") || name.contains("🇹🇼")
                || f.contains("taiwan") || f.contains("taipei")
            return isCN && !isTW
        case .japan:
            return name.contains("日本") || name.contains("🇯🇵")
                || f.contains("japan") || f.contains("tokyo") || f.contains("osaka")
        case .usa:
            return name.contains("美国") || name.contains("🇺🇸")
                || f.contains("united states") || f.contains("los angeles")
                || f.contains(" usa") || f.hasPrefix("usa") || f.contains("seattle")
                || f.contains("san jose") || f.contains("new york")
        case .singapore:
            return name.contains("新加坡") || name.contains("🇸🇬") || f.contains("singapore")
        }
    }
}

struct LocalDomainRule: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var domain: String
    var ruleType: String
    var proxy: String

    init(id: UUID = UUID(), domain: String,
         ruleType: String = "DOMAIN-SUFFIX", proxy: String = "DIRECT") {
        self.id = id
        self.domain = domain
        self.ruleType = ruleType
        self.proxy = proxy
    }

    var ruleLine: String {
        "- \(ruleType),\(domain),\(proxy)"
    }
}
