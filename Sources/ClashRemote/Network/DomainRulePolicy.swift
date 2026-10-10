import Foundation

enum DomainRulePolicy {
    static func upsertRuleLine(_ raw: String, rule: LocalDomainRule) throws -> String {
        let domain = host(from: rule.domain)
        guard !domain.isEmpty, !domain.contains(","), !domain.contains(" "),
              ["DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].contains(rule.ruleType),
              ["DIRECT", "REJECT", "GLOBAL"].contains(rule.proxy)
        else { throw HTTPError.message("域名规则无效") }
        let prefix = "\(rule.ruleType),\(domain),"
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let existing = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- \(prefix)") }
        if existing.count == 1,
           existing[0].trimmingCharacters(in: .whitespaces) == "- \(prefix)\(rule.proxy)" {
            return raw
        }
        let withoutOld = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("- \(prefix)") }
            .joined(separator: "\n")
        return try insertRuleLine(withoutOld, line: "- \(prefix)\(rule.proxy)")
    }

    static func insertRuleLine(_ raw: String, line: String) throws -> String {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains(trimmedLine) {
            throw HTTPError.message("规则已存在")
        }
        var lines = splitLines(raw)
        let entry = "  \(trimmedLine.hasPrefix("- ") ? trimmedLine : "- \(trimmedLine)")"
        if let start = lines.firstIndex(where: { SimplePolicyYAML.isTopLevel($0, header: "rules:") }) {
            lines.insert(entry, at: start + 1)
        } else {
            if let last = lines.last, last.isEmpty {
                lines.removeLast()
            }
            lines.append("rules:")
            lines.append(entry)
        }
        return joinLines(lines, trailingNewline: true)
    }

    static func match(host rawHost: String, rules: [ClashRule]) -> ClashRule? {
        let host = Self.host(from: rawHost)
        guard !host.isEmpty else { return nil }
        for rule in rules {
            switch rule.type.uppercased() {
            case "DOMAIN":
                if host == rule.payload.lowercased() { return rule }
            case "DOMAIN-SUFFIX":
                let payload = rule.payload.lowercased()
                if host == payload || host.hasSuffix("." + payload) { return rule }
            case "DOMAIN-KEYWORD":
                if host.contains(rule.payload.lowercased()) { return rule }
            default:
                continue
            }
        }
        return rules.first { $0.type.uppercased() == "MATCH" }
    }

    static func host(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        if let colon = s.lastIndex(of: ":"),
           s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func splitLines(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        var text = lines.joined(separator: "\n")
        if trailingNewline, !text.hasSuffix("\n") { text += "\n" }
        return text
    }
}
