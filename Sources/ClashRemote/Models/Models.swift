import Foundation

enum ClashPlugin: String, Codable, CaseIterable, Identifiable, Hashable {
    case openclash
    case maomao

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openclash: "OpenClash"
        case .maomao: "猫猫"
        }
    }

    var defaultHTTPPort: Int {
        switch self {
        case .openclash: 80
        case .maomao: 2333
        }
    }

    var defaultClashPort: Int {
        switch self {
        case .openclash: 9090
        case .maomao: 7788
        }
    }
}

struct RouterDevice: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var useHTTPS: Bool
    var username: String
    var password: String
    var plugin: ClashPlugin

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 80,
        useHTTPS: Bool = false,
        username: String = "root",
        password: String,
        plugin: ClashPlugin = .openclash
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.username = username
        self.password = password
        self.plugin = plugin
    }

    var baseURL: URL {
        var components = URLComponents()
        components.scheme = useHTTPS ? "https" : "http"
        components.host = host
        components.port = port
        return components.url ?? URL(string: "http://\(host)")!
    }

    var displayAddress: String {
        port == (useHTTPS ? 443 : 80) ? host : "\(host):\(port)"
    }
}

enum RuleMode: String, CaseIterable, Identifiable {
    case rule
    case global
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }

    var hint: String {
        switch self {
        case .rule: "按规则分流"
        case .global: "全部走代理"
        case .direct: "全部不走代理"
        }
    }
}

enum RunCapture: String, CaseIterable, Identifiable {
    case enhance = ""
    case tun = "-tun"
    case mix = "-mix"

    var id: String { rawValue.isEmpty ? "enhance" : rawValue }

    var title: String {
        switch self {
        case .enhance: "增强"
        case .tun: "TUN"
        case .mix: "Mix"
        }
    }

    var hint: String {
        switch self {
        case .enhance: "redir / fake-ip"
        case .tun: "内核 TUN 接管"
        case .mix: "TUN + 兼容"
        }
    }

    static func from(runMode: String) -> RunCapture {
        if runMode.hasSuffix("-tun") { return .tun }
        if runMode.hasSuffix("-mix") { return .mix }
        return .enhance
    }
}

struct OpenClashStatus: Equatable {
    var running = false
    var coreType = ""
    var dashboardHost = ""
    var dashboardPort = 9090
    var dashboardSecret = ""
    var mixedPort = ""
    var authUser = ""
    var authPass = ""
    var ruleMode: RuleMode = .rule
    var runMode = "fake-ip"
    var respectRules = false
    var metaSniffer = false
    var oversea = false
    var streamUnlock = false
    var chinaIPRoute = false
    var enabled = false
    var configPath = ""
    var hostname = ""
    var model = ""

    var configFileName: String {
        URL(fileURLWithPath: configPath).lastPathComponent
    }

    var tunOn: Bool {
        runMode.contains("tun") || runMode.contains("mix")
    }
}

struct TrafficSnapshot: Equatable {
    var up = "0 B/S"
    var down = "0 B/S"
    var upTotal = "0 B"
    var downTotal = "0 B"
    var connections = 0
    var cpu = "0"
    var mem = "—"
}

struct ConfigFile: Identifiable, Hashable {
    var name: String
    var path: String
    var size: Int
    var current: Bool

    var id: String { path.isEmpty ? name : path }
}

struct Subscription: Identifiable, Hashable {
    var section: String
    var name: String
    var address: String
    var enabled: Bool
    var userAgent: String

    var id: String { section }
}

enum NodeRegion: String {
    case hongkong = "香港"
    case singapore = "新加坡"
    case other = "其它"

    static func of(_ name: String) -> NodeRegion {
        let folded = name.lowercased()
        if name.contains("香港") || name.contains("🇭🇰")
            || folded.contains("hong kong") || folded.contains("hongkong")
            || folded.contains("hong-kong") {
            return .hongkong
        }
        if name.contains("新加坡") || name.contains("🇸🇬")
            || folded.contains("singapore") {
            return .singapore
        }
        return .other
    }
}

struct ProxyItem: Identifiable, Hashable {
    var name: String
    var type: String
    var lastDelay: Int?
    var ownerGroup: String = ""

    var id: String { name }

    var typeLabel: String {
        switch type.lowercased() {
        case "selector": "选择"
        case "urltest", "url-test": "自动"
        case "fallback": "故障转移"
        case "loadbalance", "load-balance": "负载均衡"
        case "direct": "Direct"
        case "reject": "Reject"
        case "compatible": "兼容"
        default: type
        }
    }
}

struct ProxyGroup: Identifiable, Hashable {
    var name: String
    var type: String
    var now: String
    var nodes: [ProxyItem]
    var selectable: Bool

    var id: String { name }

    var typeLabel: String {
        switch type.lowercased() {
        case "selector": "选择"
        case "urltest", "url-test": "自动"
        case "fallback": "故障转移"
        case "loadbalance", "load-balance": "负载均衡"
        case "relay": "中继"
        default: type
        }
    }

    /// Selector / URLTest / Fallback 等都可以用 Clash API 切换 now。
    var allowsManualSelect: Bool {
        Self.allowsManualSelect(type: type, name: name)
    }

    static func allowsManualSelect(type: String, name: String) -> Bool {
        switch type.lowercased() {
        case "selector", "urltest", "url-test", "fallback",
             "loadbalance", "load-balance", "relay", "compatible":
            return true
        default:
            return name == "GLOBAL"
        }
    }
}

/// 当前实际生效的叶子节点（策略组可能嵌套，需解析到具体节点）。
struct ActiveNodeInfo: Equatable {
    var rootGroup: String
    var leafName: String
    var chain: [String]

    /// 完整链路，例如「节点选择 / 新加坡 / SG-xxx」。
    var displayPath: String {
        chain.joined(separator: " / ")
    }

    /// 叶子所属的策略组（嵌套时取倒数第二段）。
    var ownerGroupName: String {
        if chain.count >= 2 {
            return chain[chain.count - 2]
        }
        return rootGroup
    }
}

struct ClashRule: Identifiable, Hashable {
    var type: String
    var payload: String
    var proxy: String

    var id: String { "\(type)|\(payload)|\(proxy)" }

    var line: String {
        payload.isEmpty ? "\(type),\(proxy)" : "\(type),\(payload),\(proxy)"
    }
}

struct FailoverEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var at: Date
    var from: String
    var to: String
    var delay: Int
    var source: String

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        from: String,
        to: String,
        delay: Int,
        source: String
    ) {
        self.id = id
        self.at = at
        self.from = from
        self.to = to
        self.delay = delay
        self.source = source
    }
}

struct DeviceFailoverStatus: Equatable {
    var installed = false
    var hooked = false
    var running = false
    var enabled = true
    var interval = 5
    var detail = ""
    var log = ""
    var updatedAt: Date?

    var isLive: Bool { installed && running && enabled }

    var phaseTitle: String {
        if !installed { return "还没装到设备" }
        if !enabled { return "检测关着" }
        if !running { return "守护没在跑" }
        if detail.hasPrefix("pinned") { return "已固定当前节点，只有超时才换" }
        if detail.hasPrefix("ok ") { return "刚才测过，节点是通的" }
        if detail.hasPrefix("slow or timeout") || detail.hasPrefix("timeout") { return "当前节点超时，正在换" }
        if detail.hasPrefix("switched") { return "刚换了节点" }
        if detail.hasPrefix("no faster candidate") { return "没有更快的可用节点" }
        if detail.hasPrefix("skip") { return "这一轮跳过" }
        if detail.hasPrefix("excluded") { return "当前节点被排除，正在找替代" }
        if detail.contains("not ready") { return "核心还没起来" }
        if detail == "disabled" { return "检测关着" }
        if detail.hasPrefix("loop start") { return "守护刚启动，等下一轮" }
        return running ? "守护运行中" : "未知"
    }

    var probeLine: String {
        if detail.isEmpty { return "还没有测过" }
        return detail
    }
}

enum AppNotice: Equatable {
    case info(String)
    case success(String)
    case error(String)

    var text: String {
        switch self {
        case .info(let s), .success(let s), .error(let s): s
        }
    }
}
