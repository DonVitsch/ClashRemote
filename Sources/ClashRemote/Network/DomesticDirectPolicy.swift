import Foundation

/// 微信公众号、美团下单等国内服务：域名不在 GEOSITE/CN 或 IP 非大陆时，会被 MATCH 送去代理。
enum DomesticDirectPolicy {
    static let markerBegin = "# ClashRemote: 国内直连"
    static let markerEnd = "# ClashRemote: 国内直连 end"

    static let domains: [String] = [
        // 微信公众号 / 小程序
        "weixin.qq.com",
        "weixin.com",
        "wechat.com",
        "weixinbridge.com",
        "servicewechat.com",
        "wx.qq.com",
        "wxs.qq.com",
        "qpic.cn",
        "qlogo.cn",
        "idqqimg.com",
        "gtimg.cn",
        // 美团 / 点评（下单大量走 sankuai.com，不在常见 CN 列表里）
        "meituan.com",
        "meituan.net",
        "meituan.com.cn",
        "dianping.com",
        "dpfile.com",
        "kuxun.cn",
        "sankuai.com",
        "sankuai.info",
        // 抖音评论头像 / 图：走海外 CDN IP 或 fake-ip 时签名校验失败
        "douyin.com",
        "iesdouyin.com",
        "iesdouyin.net",
        "douyinpic.com",
        "idouyinpic.com",
        "douyinstatic.com",
        "idouyinstatic.com",
        "douyincdn.com",
        "amemv.com",
        "amemv.cn",
        "snssdk.com",
        "byteimg.com",
        "byteacctimg.com",
        "bytemaimg.com",
        "bytegoofy.com",
        "bytegecko.com",
        "bytescm.com",
        "bytednsdoc.com",
        "bytexservice.com",
        "bytecdn.cn",
        "pstatp.com",
        "toutiaoimg.com",
        "toutiaoimg.cn",
        "bytetos.com",
        "ecombdimg.com",
        "huoshanimg.com",
        "bdurl.net",
        "zjcdn.com",
        "bytedance.com",
        "volces.com",
        // 完美校园（open.17wanxiao.com 及 App API）
        "17wanxiao.com",
        "wanxiao.com"
    ]

    /// 评论图常见 `p3-pc-sign.douyinpic.com`、`p*-*.byteimg.com`，单靠后缀不够稳。
    static let keywords: [String] = [
        "mmbiz",
        "douyinpic",
        "byteimg",
        "toutiaoimg",
        "wanxiao"
    ]

    static func ruleLines() -> [String] {
        var lines = ["  \(markerBegin)"]
        for keyword in keywords {
            lines.append("  - DOMAIN-KEYWORD,\(keyword),DIRECT")
        }
        for domain in domains {
            lines.append("  - DOMAIN-SUFFIX,\(domain),DIRECT")
        }
        lines.append("  \(markerEnd)")
        return lines
    }

    static func isCovered(by rules: [ClashRule]) -> Bool {
        requiredSuffixes.allSatisfy { suffix in
            rules.contains {
                $0.type.uppercased() == "DOMAIN-SUFFIX"
                    && $0.payload.lowercased() == suffix
                    && $0.proxy == "DIRECT"
            }
        }
    }

    private static let requiredSuffixes = [
        "sankuai.com",
        "byteimg.com",
        "douyinpic.com",
        "17wanxiao.com"
    ]

    /// 扁平化后国内组已删除，规则目标还写着旧组名就会匹配失败，流量掉进 MATCH 走代理。
    static func rewriteLegacyDomesticTarget(_ line: String) -> String {
        var result = line
        for alias in ["🇨🇳 大陆", "国内网络", "国内直连"] {
            result = result.replacingOccurrences(of: "," + alias, with: ",DIRECT")
        }
        return result
    }
}
