import Foundation

/// 猫猫（minikano / mihomo）配置的策略组收敛。
///
/// 猫猫的 config.yaml 是插件生成的**完整** mihomo 配置，策略组按用途分好
/// （选择节点 / AIGPT / Netflix&Disney / Steam login / 国内网站 / 拦截广告 / 漏网之鱼 …）。
/// 这些组的节点来源都是 proxy-providers，所以可以安全地收成一个「节点选择」组。
///
/// ⚠️ 但有两条硬约束，踩过就知道内核会直接拒绝启动：
/// 1. 被删掉的组名在**规则目标**里被引用（`- GEOSITE,netflix,Netflix&Disney`）→ 必须重映射；
/// 2. 被删掉的组名还会出现在**保留下来的组**的 `proxies:` 里（`国内网站: [DIRECT, 选择节点]`）
///    → 也必须一起重映射。漏掉第 2 条时内核报
///    `proxy group[0]: 国内网站: '选择节点' not found` 然后拒绝启动。
///
/// 保留规则：`proxies:` 里**第一项是 DIRECT / REJECT / PASS** 的组视为"直连组/拦截组"，
/// 它们不是用来挑节点的，删了会导致国内流量走代理、广告不拦 —— 所以保留。
enum MaoMaoPolicyYAML {
    static let groupName = "节点选择"

    private static let builtins: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"
    ]

    private static let topLevelKey = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9_-]*:"#)

    static func rewrite(_ raw: String, excludeRegex: String) throws -> String {
        var lines = raw.components(separatedBy: "\n")

        guard let providerRange = block(named: "proxy-providers", in: lines) else {
            throw HTTPError.message("配置里没有 proxy-providers，无法收敛策略组。")
        }
        let providers = providerNames(in: content(of: providerRange, in: lines))
        guard !providers.isEmpty else {
            throw HTTPError.message("proxy-providers 里一个订阅都没有，已中止（否则会生成空组）。")
        }

        guard let groupRange = block(named: "proxy-groups", in: lines) else {
            throw HTTPError.message("配置里没有 proxy-groups。")
        }
        let items = groupItems(in: content(of: groupRange, in: lines))

        // 保留"直连组/拦截组"，其余合并进「节点选择」
        var kept: [[String]] = []
        var merged: Set<String> = []
        for item in items {
            guard let name = value(of: "name", in: item) else { continue }
            let proxies = list(of: "proxies", in: item)
            if let first = proxies.first, builtins.contains(first) {
                kept.append(item)
            } else {
                merged.insert(name)
            }
        }
        merged.remove(groupName)

        var remap: [String: String] = [:]
        for name in merged { remap[name] = groupName }

        let newGroup = [
            "    - name: \(groupName)",
            "      type: select",
            "      use:"
        ] + providers.map { "        - \($0)" } + [
            "      filter: .*"
        ] + (excludeRegex.isEmpty ? [] : ["      exclude-filter: \"\(excludeRegex)\""])

        let keptLines = kept.flatMap { remapReferences(in: $0, using: remap) }
        let newGroups = newGroup + keptLines

        var out = Array(lines[..<groupRange.lowerBound])
        out.append(contentsOf: ["proxy-groups:"] + newGroups)
        out.append(contentsOf: lines[groupRange.upperBound...])

        if let ruleRange = block(named: "rules", in: out) {
            var next = Array(out[..<ruleRange.lowerBound])
            next.append("rules:")
            next.append(contentsOf: remapReferences(in: content(of: ruleRange, in: out), using: remap))
            next.append(contentsOf: out[ruleRange.upperBound...])
            out = next
        }

        let text = out.joined(separator: "\n")

        // 悬空引用自检：任何一个被删掉的组名还有残留，写下去内核就起不来。
        var leftover: [String] = []
        for name in merged {
            if text.contains(",\(name)") || text.contains("- \(name)") { leftover.append(name) }
        }
        guard leftover.isEmpty else {
            throw HTTPError.message("收敛后仍有悬空引用：\(leftover.joined(separator: "、"))，已中止以免内核起不来。")
        }

        // rule-set 自检：规则里引用的 rule-set 必须都在 rule-providers 里定义。
        // 名字被误改过一次（`iAIGPT` → `i节点选择`），内核就是因此拒绝启动的。
        if let rp = block(named: "rule-providers", in: out) {
            let defined = Set(content(of: rp, in: out).compactMap {
                firstMatch(#"^ {4}([A-Za-z0-9_-]+):\s*$"#, in: $0)
            })
            if !defined.isEmpty {
                // 只取标识符字符：像 `AND,((RULE-SET,iCNdomain),(NOT,...))` 这种嵌在括号里的写法，
                // 后面跟的是 `)))` 而不是逗号。
                let referenced = Set(captures(#"RULE-SET,([A-Za-z0-9_.-]+)"#, in: text))
                let missing = referenced.subtracting(defined)
                guard missing.isEmpty else {
                    throw HTTPError.message(
                        "规则引用了不存在的 rule-set：\(missing.sorted().joined(separator: "、"))，已中止。"
                    )
                }
            }
        }

        guard text.contains(",\(groupName)") || text.contains("- \(groupName)") || text.contains("name: \(groupName)") else {
            throw HTTPError.message("收敛后没有任何地方引用「\(groupName)」，已中止。")
        }
        if raw.hasSuffix("\n"), !text.hasSuffix("\n") { return text + "\n" }
        return text
    }

    // MARK: - 解析

    /// 顶层块的 `[key 行, 结束)` —— **含** `key:` 那一行，方便整块替换。
    private static func block(named key: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0 == "\(key):" }) else { return nil }
        let end = (start + 1 ..< lines.count).first { isTopLevelKey(lines[$0]) } ?? lines.count
        return start ..< end
    }

    /// 块内内容（不含 `key:` 那一行）。
    private static func content(of range: Range<Int>, in lines: [String]) -> [String] {
        Array(lines[(range.lowerBound + 1)..<range.upperBound])
    }

    private static func isTopLevelKey(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return topLevelKey.firstMatch(in: line, range: range) != nil
    }

    private static func providerNames(in lines: [String]) -> [String] {
        lines.compactMap { line -> String? in
            guard let m = firstMatch(#"^ {4}([A-Za-z0-9_-]+):\s*$"#, in: line) else { return nil }
            return m
        }
    }

    /// 每个组以 `    - ` 开头，到下一个同级项为止。
    private static func groupItems(in lines: [String]) -> [[String]] {
        var items: [[String]] = []
        var current: [String]?
        for line in lines {
            if line.hasPrefix("    - ") {
                if let current { items.append(current) }
                current = [line]
            } else if current != nil {
                current?.append(line)
            }
        }
        if let current { items.append(current) }
        return items
    }

    private static func value(of key: String, in item: [String]) -> String? {
        for line in item {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 取 `key:` 下面缩进更深的 `- xxx` 列表。
    private static func list(of key: String, in item: [String]) -> [String] {
        var result: [String] = []
        var inside = false
        for line in item {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") { inside = true; continue }
            guard inside else { continue }
            if trimmed.hasPrefix("- ") {
                result.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !trimmed.isEmpty {
                inside = false
            }
        }
        return result
    }

    /// 把规则目标 `,组名` 和组内 `- 组名` 换成新名字。
    ///
    /// ⚠️ 前置必须是**至少一个逗号**。像 `- RULE-SET,iAIGPT,AIGPT` 这种，规则集名字里也含 `AIGPT`，
    /// 前置允许为空的话会把 `iAIGPT` 一起改成 `i节点选择`，内核直接报
    /// `rule set [i节点选择] not found` 拒绝启动。
    private static func remapReferences(in lines: [String], using remap: [String: String]) -> [String] {
        guard !remap.isEmpty else { return lines }
        return lines.map { line in
            var result = line
            for (old, new) in remap {
                let escaped = NSRegularExpression.escapedPattern(for: old)
                // 规则目标：必须在行尾，后面允许跟 `,no-resolve` 之类的 flag
                result = result.replacingOccurrences(
                    of: #"(,+\s*)"# + escaped + #"((?:,[A-Za-z][A-Za-z-]*)*)\s*$"#,
                    with: "$1" + new + "$2",
                    options: .regularExpression
                )
                // 组内 proxies 列表项：`- 组名` 独占一行
                result = result.replacingOccurrences(
                    of: #"^(\s*- )"# + escaped + #"\s*$"#,
                    with: "$1" + new,
                    options: .regularExpression
                )
            }
            return result
        }
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func firstMatch(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }
}
